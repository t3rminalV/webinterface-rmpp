#!/usr/bin/env bash
# uninstall.sh -- revert everything install.sh did, on a Paper Pro.
# SPDX-License-Identifier: MIT
#
# Usage (as root on the device):
#   bash /home/root/.local/share/webinterface-rmpp/uninstall.sh
#
# Flags:
#   --keep-conf      leave xochitl.conf as-is (don't restore backup)
#   --keep-config    keep wifi.env + tls/ (preserves credentials for re-install)

set -eu

KEEP_CONF=0
KEEP_CONFIG=0
while [ $# -gt 0 ]; do
	case "$1" in
		--keep-conf)   KEEP_CONF=1; shift ;;
		--keep-config) KEEP_CONFIG=1; shift ;;
		-h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "error: must be run as root" >&2; exit 1
fi

NETWORKD_DROPIN='/etc/systemd/network/05-webinterface-alwayson.network'
MDNS_DROPIN='/etc/systemd/network/25-wlan0.network.d/10-webinterface-mdns.conf'
WIFI_SERVICE_UNIT='/etc/systemd/system/webinterface-wifi.service'
WIFI_SOCKET_UNIT='/etc/systemd/system/webinterface-wifi.socket'   # legacy 0.1.x
WANTS_LINK='/etc/systemd/system/multi-user.target.wants/webinterface-wifi.service'
BIN_FILE='/home/root/.local/bin/webinterface-rmpp'
PROXY_BIN='/home/root/.local/bin/webinterface-wifi-proxy'
SHARE_DIR='/home/root/.local/share/webinterface-rmpp'
CONFIG_DIR='/home/root/.config/webinterface-rmpp'
XOCHITL_CONF='/home/root/.config/remarkable/xochitl.conf'
XOCHITL_CONF_BAK="${XOCHITL_CONF}.webint-rmpp.bak"

# Bypass the /etc overlay (tmpfs upperdir) by mounting the root block
# device a second time. See install.sh for the long-form rationale.
etc_persist_remove() {
	local path=$1 rootdev mnt token

	# Same multi-source detection as install.sh; see there for rationale.
	rootdev=$(awk '$2 == "/" && $3 != "overlay" {print $1; exit}' /proc/mounts)
	if [ -z "$rootdev" ] || [ ! -b "$rootdev" ] || [ "$rootdev" = "/dev/root" ]; then
		if [ -L /dev/root ]; then
			rootdev=$(readlink -f /dev/root 2>/dev/null)
		fi
	fi
	if [ -z "$rootdev" ] || [ ! -b "$rootdev" ]; then
		for token in $(cat /proc/cmdline 2>/dev/null); do
			case "$token" in
				root=/dev/*) rootdev=${token#root=}; break ;;
			esac
		done
	fi
	if [ -z "$rootdev" ] || [ ! -b "$rootdev" ]; then
		echo "warn: could not identify root block device; lower /etc not cleaned" >&2
		return 0
	fi

	mnt=/run/webint-rmpp-lower
	mkdir -p "$mnt"
	if ! mount "$rootdev" "$mnt" 2>/dev/null \
	|| ! mount -o remount,rw "$mnt" 2>/dev/null; then
		echo "warn: could not bypass /etc overlay to remove ${path}" >&2
		umount "$mnt" 2>/dev/null || true
		rmdir "$mnt" 2>/dev/null || true
		return 0
	fi
	rm -f "${mnt}${path}"
	mount -o remount,ro "$mnt" 2>/dev/null || true
	umount "$mnt" 2>/dev/null || true
	rmdir "$mnt" 2>/dev/null || true
}

echo "stopping wifi proxy..."
systemctl stop webinterface-wifi.service webinterface-wifi.socket 2>/dev/null || true

echo "removing systemd assets from the running session..."
systemctl disable webinterface-wifi.service 2>/dev/null || true
systemctl disable webinterface-wifi.socket  2>/dev/null || true
rm -f "$NETWORKD_DROPIN" "$MDNS_DROPIN" \
      "$WIFI_SERVICE_UNIT" "$WIFI_SOCKET_UNIT" "$WANTS_LINK"

echo "removing persistent copies from the underlying ext4..."
etc_persist_remove "$NETWORKD_DROPIN"
etc_persist_remove "$MDNS_DROPIN"
etc_persist_remove "$WIFI_SERVICE_UNIT"
etc_persist_remove "$WIFI_SOCKET_UNIT"
etc_persist_remove "$WANTS_LINK"

systemctl daemon-reload
networkctl reload 2>/dev/null || true
networkctl reconfigure usb1 >/dev/null 2>&1 || true

if [ $KEEP_CONF -eq 0 ] && [ -f "$XOCHITL_CONF_BAK" ]; then
	echo "restoring xochitl.conf from backup..."
	mv "$XOCHITL_CONF_BAK" "$XOCHITL_CONF"
fi

[ -f "$BIN_FILE" ]  && rm -f "$BIN_FILE"
[ -f "$PROXY_BIN" ] && rm -f "$PROXY_BIN"
[ -d "$SHARE_DIR" ] && rm -rf "$SHARE_DIR"
if [ $KEEP_CONFIG -eq 0 ] && [ -d "$CONFIG_DIR" ]; then
	rm -rf "$CONFIG_DIR"
fi

echo "uninstall complete"
echo "note: this does NOT remove the PATH= line added to /home/root/.bashrc"
echo "      nor /home/root/.local/bin if empty -- remove by hand if you want."
