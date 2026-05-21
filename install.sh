#!/usr/bin/env bash
# install.sh -- install webinterface-rmpp on a reMarkable Paper Pro.
# SPDX-License-Identifier: MIT
#
# Run as root on the device, from this tarball's extracted directory:
#   tar xzf webinterface-rmpp-*.tar.gz
#   cd webinterface-rmpp-*
#   bash install.sh
#
# Flags:
#   --wifi-port N         listen port (default 443)
#   --wifi-user NAME      basic auth username (default 'admin')
#   --wifi-pass PASSWORD  basic auth password (else prompted interactively)
#   --tls-days N          self-signed cert validity (default 3650)
#   --san HOST,HOST,...   extra SAN entries (auto-detected ones are kept)
#   --no-wifi             skip installing the wifi proxy entirely
#   --no-enable           install everything but don't enable wifi proxy
#   -h, --help            this message

set -eu

WEBINT_RMPP_VERSION='0.9.0'

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- defaults ------------------------------------------------------------
WIFI_PORT=443
WIFI_USER=admin
WIFI_PASS=''
DO_WIFI=1
DO_ENABLE=1
TLS_DAYS=3650
EXTRA_SANS=''

# --- args ----------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
		--wifi-port)   WIFI_PORT="${2:-}";   shift 2 ;;
		--wifi-port=*) WIFI_PORT="${1#*=}";  shift ;;
		--wifi-user)   WIFI_USER="${2:-}";   shift 2 ;;
		--wifi-user=*) WIFI_USER="${1#*=}";  shift ;;
		--wifi-pass)   WIFI_PASS="${2:-}";   shift 2 ;;
		--wifi-pass=*) WIFI_PASS="${1#*=}";  shift ;;
		--tls-days)    TLS_DAYS="${2:-}";    shift 2 ;;
		--tls-days=*)  TLS_DAYS="${1#*=}";   shift ;;
		--san)         EXTRA_SANS="${2:-}";  shift 2 ;;
		--san=*)       EXTRA_SANS="${1#*=}"; shift ;;
		--no-wifi)     DO_WIFI=0; shift ;;
		--no-enable)   DO_ENABLE=0; shift ;;
		-h|--help)
			sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

# Validate the port; 443 is the default (HTTPS).
case "$WIFI_PORT" in
	''|*[!0-9]*) echo "--wifi-port must be numeric" >&2; exit 2 ;;
esac
if [ "$WIFI_PORT" -lt 1 ] || [ "$WIFI_PORT" -gt 65535 ]; then
	echo "--wifi-port out of range 1..65535" >&2; exit 2
fi
case "$TLS_DAYS" in
	''|*[!0-9]*) echo "--tls-days must be numeric" >&2; exit 2 ;;
esac

# --- colours -------------------------------------------------------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; NC=$'\033[0m'

# --- /etc overlay-bypass helpers -----------------------------------------
# On the Paper Pro /etc is an overlayfs whose upperdir is tmpfs, so
# ordinary writes to /etc vanish on reboot. These helpers mount the root
# block device a SECOND time at /run/webint-rmpp-lower. The second mount
# shares the same ext4 superblock as / but has NO overlay layered on it,
# so writes under that mountpoint go straight to the persistent
# filesystem. Because the superblock is shared, remounting rw at the
# second mount briefly makes / rw as well; we put it back to ro before
# umount.
#
# The running session also writes to /etc the normal way (lands in the
# tmpfs upperdir) so daemon-reload / enable / start work immediately.
_etc_persist_rootdev() {
	# Find the block device backing /. Try sources in order of canonicity.
	local dev token

	# 1. /proc/mounts -- canonical, but on this kernel often prints
	#    "/dev/root" (an alias) instead of the real device.
	dev=$(awk '$2 == "/" && $3 != "overlay" {print $1; exit}' /proc/mounts)
	if [ -n "$dev" ] && [ -b "$dev" ] && [ "$dev" != "/dev/root" ]; then
		echo "$dev"; return 0
	fi

	# 2. /dev/root, if it's a symlink to the real device.
	if [ -L /dev/root ]; then
		dev=$(readlink -f /dev/root 2>/dev/null)
		if [ -n "$dev" ] && [ -b "$dev" ]; then
			echo "$dev"; return 0
		fi
	fi

	# 3. /proc/cmdline -- the bootloader explicitly tells us. On the
	#    Paper Pro we see e.g. "root=/dev/mmcblk0p3".
	for token in $(cat /proc/cmdline 2>/dev/null); do
		case "$token" in
			root=/dev/*)
				dev=${token#root=}
				if [ -b "$dev" ]; then echo "$dev"; return 0; fi ;;
			root=PARTUUID=*|root=UUID=*|root=LABEL=*)
				# blkid would resolve this but isn't guaranteed on busybox;
				# skip and let the caller fail clearly.
				;;
		esac
	done

	return 1
}

_etc_persist_with_lower() {
	# _etc_persist_with_lower <callback> <args...>
	# Mounts the root block device a SECOND time at a fresh path so the
	# overlay isn't layered on it, calls <callback> with $1 = that
	# mountpoint, then tears everything back down.
	local cb=$1; shift
	local rootdev mnt rc=0

	rootdev=$(_etc_persist_rootdev)
	if [ -z "$rootdev" ] || [ ! -b "$rootdev" ]; then
		[ -L /dev/root ] && rootdev=$(readlink -f /dev/root)
	fi
	if [ -z "$rootdev" ] || [ ! -b "$rootdev" ]; then
		echo -e "${RED}error:${NC} could not identify root block device" >&2
		return 1
	fi

	mnt=/run/webint-rmpp-lower
	mkdir -p "$mnt"

	if ! mount "$rootdev" "$mnt" 2>/dev/null; then
		echo -e "${RED}error:${NC} could not mount $rootdev at $mnt" >&2
		rmdir "$mnt" 2>/dev/null || true
		return 1
	fi
	if ! mount -o remount,rw "$mnt"; then
		echo -e "${RED}error:${NC} could not remount $mnt rw" >&2
		umount "$mnt" 2>/dev/null || true
		rmdir "$mnt" 2>/dev/null || true
		return 1
	fi

	"$cb" "$mnt" "$@" || rc=$?

	# Restore ro and tear down -- ro on the shared superblock affects /
	# too, which is the state we want.
	mount -o remount,ro "$mnt" 2>/dev/null || true
	umount "$mnt" 2>/dev/null || true
	rmdir "$mnt" 2>/dev/null || true
	return $rc
}

_etc_persist_cb_write() {
	local mnt=$1 src=$2 dst=$3 mode=$4
	local lower="${mnt}${dst}"
	mkdir -p "$(dirname "$lower")"
	cp "$src" "$lower"
	chmod "$mode" "$lower"
}
_etc_persist_cb_symlink() {
	local mnt=$1 target=$2 link=$3
	local lower="${mnt}${link}"
	mkdir -p "$(dirname "$lower")"
	ln -sfn "$target" "$lower"
}
_etc_persist_cb_remove() {
	local mnt=$1 path=$2
	rm -f "${mnt}${path}"
}

etc_persist()         { _etc_persist_with_lower _etc_persist_cb_write   "$1" "$2" "$3"; }
etc_persist_symlink() { _etc_persist_with_lower _etc_persist_cb_symlink "$1" "$2"; }
etc_persist_remove()  { _etc_persist_with_lower _etc_persist_cb_remove  "$1"; }

# --- target paths --------------------------------------------------------
BIN_DIR='/home/root/.local/bin'
BIN_FILE="${BIN_DIR}/webinterface-rmpp"
PROXY_BIN="${BIN_DIR}/webinterface-wifi-proxy"
SHARE_DIR='/home/root/.local/share/webinterface-rmpp'
UNINSTALL_FILE="${SHARE_DIR}/uninstall.sh"
STATE_FILE="${SHARE_DIR}/install-state"
CONFIG_DIR='/home/root/.config/webinterface-rmpp'
WIFI_ENV="${CONFIG_DIR}/wifi.env"
TLS_DIR="${CONFIG_DIR}/tls"
TLS_CERT="${TLS_DIR}/cert.pem"
TLS_KEY="${TLS_DIR}/key.pem"

NETWORKD_DROPIN='/etc/systemd/network/05-webinterface-alwayson.network'
MDNS_DROPIN='/etc/systemd/network/25-wlan0.network.d/10-webinterface-mdns.conf'
WIFI_SERVICE_UNIT='/etc/systemd/system/webinterface-wifi.service'
XOCHITL_CONF='/home/root/.config/remarkable/xochitl.conf'

SRC_CLI="${SELF_DIR}/webinterface-rmpp"
SRC_PROXY="${SELF_DIR}/webinterface-wifi-proxy"
SRC_DROPIN="${SELF_DIR}/units/05-webinterface-alwayson.network"
SRC_MDNS="${SELF_DIR}/units/25-wlan0.network.d/10-webinterface-mdns.conf"
SRC_SERVICE="${SELF_DIR}/units/webinterface-wifi.service"
SRC_UNINSTALL="${SELF_DIR}/uninstall.sh"

# --- preflight -----------------------------------------------------------
echo -e "${GREEN}webinterface-rmpp installer ${WEBINT_RMPP_VERSION}${NC}"
echo

if [ "$(id -u)" -ne 0 ]; then
	echo -e "${RED}error:${NC} must be run as root" >&2; exit 1
fi

for f in "$SRC_CLI" "$SRC_DROPIN" "$SRC_MDNS" "$SRC_SERVICE" "$SRC_UNINSTALL"; do
	[ -f "$f" ] || { echo -e "${RED}error:${NC} missing $f" >&2; exit 1; }
done
if [ $DO_WIFI -eq 1 ]; then
	[ -f "$SRC_PROXY" ] || {
		echo -e "${RED}error:${NC} missing $SRC_PROXY (proxy binary)" >&2
		echo "       rebuild with: bash build.sh" >&2; exit 1; }
	# Skip the ELF magic-byte check here -- BusyBox's od/dd format quirks
	# made it unreliable, and the kernel rejects a non-ELF binary with a
	# clear error at exec time. The build script already validates arch.
fi

if ! mount -o remount,rw / 2>/dev/null; then
	echo -e "${RED}error:${NC} cannot remount / read-write" >&2; exit 1
fi
mount -o remount,ro / 2>/dev/null || true

# Collect password if not provided and not already saved.
if [ $DO_WIFI -eq 1 ] && [ -z "$WIFI_PASS" ]; then
	if [ -f "$WIFI_ENV" ] && grep -q '^AUTH_PASS=.\+' "$WIFI_ENV"; then
		echo -e "${CYAN}note:${NC} keeping existing AUTH_PASS from ${WIFI_ENV}"
		WIFI_PASS="$(awk -F= '/^AUTH_PASS=/{sub(/^[^=]*=/, ""); print; exit}' "$WIFI_ENV")"
		eu="$(awk -F= '/^AUTH_USER=/{sub(/^[^=]*=/, ""); print; exit}' "$WIFI_ENV")"
		[ -n "$eu" ] && WIFI_USER="$eu"
	else
		echo "wifi proxy basic-auth credentials:"
		printf '  username [%s]: ' "$WIFI_USER"
		read -r u; [ -n "$u" ] && WIFI_USER="$u"
		printf '  password (input hidden): '
		stty -echo 2>/dev/null; read -r WIFI_PASS; stty echo 2>/dev/null; printf '\n'
		if [ -z "$WIFI_PASS" ]; then
			echo -e "${RED}error:${NC} password is required (or pass --wifi-pass)" >&2; exit 1
		fi
		printf '  confirm:                '
		stty -echo 2>/dev/null; read -r WIFI_PASS2; stty echo 2>/dev/null; printf '\n'
		if [ "$WIFI_PASS" != "$WIFI_PASS2" ]; then
			echo -e "${RED}error:${NC} passwords do not match" >&2; exit 1
		fi
		echo
	fi
fi

echo "  wifi install:    $([ $DO_WIFI -eq 1 ] && echo yes || echo no)"
echo "  scheme:          https"
echo "  port:            ${WIFI_PORT}"
echo "  enable on boot:  $([ $DO_ENABLE -eq 1 ] && echo yes || echo no)"
[ $DO_WIFI -eq 1 ] && echo "  auth user:       ${WIFI_USER}"
echo

remount_rw() { mount -o remount,rw / 2>/dev/null || { echo "${RED}error:${NC} remount,rw failed" >&2; exit 1; }; }
remount_ro() { mount -o remount,ro / 2>/dev/null || true; }

# --- 1. xochitl.conf -----------------------------------------------------
echo -e "${CYAN}[1/6]${NC} ensuring WebInterfaceEnabled=true"
mkdir -p "$(dirname "$XOCHITL_CONF")"
if [ ! -f "$XOCHITL_CONF" ]; then
	printf '[General]\nWebInterfaceEnabled=true\n' > "$XOCHITL_CONF"
elif grep -q '^WebInterfaceEnabled=' "$XOCHITL_CONF"; then
	cp "$XOCHITL_CONF" "${XOCHITL_CONF}.webint-rmpp.bak"
	sed -i 's/^WebInterfaceEnabled=.*/WebInterfaceEnabled=true/' "$XOCHITL_CONF"
elif grep -q '^\[General\]' "$XOCHITL_CONF"; then
	cp "$XOCHITL_CONF" "${XOCHITL_CONF}.webint-rmpp.bak"
	sed -i '/^\[General\]/a WebInterfaceEnabled=true' "$XOCHITL_CONF"
else
	cp "$XOCHITL_CONF" "${XOCHITL_CONF}.webint-rmpp.bak"
	printf '\n[General]\nWebInterfaceEnabled=true\n' >> "$XOCHITL_CONF"
fi
echo "      done"

# --- 2. install /home payloads (CLI, proxy binary) -----------------------
echo -e "${CYAN}[2/6]${NC} installing CLI + binary under /home"
mkdir -p "$BIN_DIR" "$SHARE_DIR" "$CONFIG_DIR" "$TLS_DIR"
cp "$SRC_CLI" "$BIN_FILE" && chmod 0755 "$BIN_FILE"
if [ $DO_WIFI -eq 1 ]; then
	cp "$SRC_PROXY" "$PROXY_BIN" && chmod 0755 "$PROXY_BIN"
fi
cp "$SRC_UNINSTALL" "$UNINSTALL_FILE" && chmod 0755 "$UNINSTALL_FILE"

case ":${PATH:-}:" in
	*:${BIN_DIR}:*) ;;
	*) echo "PATH=\"${BIN_DIR}:\$PATH\"" >> /home/root/.bashrc ;;
esac
echo "      done"

# --- 3. cert: always generate (HTTPS-only) ------------------------------
if [ $DO_WIFI -eq 1 ]; then
	echo -e "${CYAN}[3/6]${NC} preparing TLS certificate"
	if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
		echo "      reusing existing ${TLS_CERT}"
	else
		host=$(hostname 2>/dev/null || echo rmpp)
		wlan=$(ip -4 addr show dev wlan0 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
		san="${host},${host}.local,localhost,remarkable.local,127.0.0.1,10.11.99.1"
		[ -n "$wlan" ] && san="${san},${wlan}"
		[ -n "$EXTRA_SANS" ] && san="${san},${EXTRA_SANS}"
		echo "      generating self-signed cert (SAN: ${san})"
		"$PROXY_BIN" gen-cert \
			--cert "$TLS_CERT" --key "$TLS_KEY" \
			--san "$san" --days "$TLS_DAYS" \
			--cn "reMarkable Paper Pro (${host})" >/dev/null
		chmod 0644 "$TLS_CERT"
		chmod 0600 "$TLS_KEY"
	fi
else
	echo -e "${CYAN}[3/6]${NC} skipping cert generation (--no-wifi)"
fi

# --- 4. wifi.env ---------------------------------------------------------
echo -e "${CYAN}[4/6]${NC} writing ${WIFI_ENV} (mode 0600)"
if [ $DO_WIFI -eq 1 ]; then
	umask_old=$(umask); umask 077
	{
		echo "# webinterface-rmpp wifi proxy env -- mode 0600"
		echo "LISTEN_ADDR=:${WIFI_PORT}"
		# LISTEN_DEVICE intentionally unset so the proxy listens on
		# 0.0.0.0:<port> and survives wifi IP changes automatically.
		# Set this to 'wlan0' if you need to restrict the listen IP.
		echo "LISTEN_DEVICE="
		echo "TARGET=10.11.99.1:80"
		echo "AUTH_USER=${WIFI_USER}"
		echo "AUTH_PASS=${WIFI_PASS}"
		echo "TLS_CERT=${TLS_CERT}"
		echo "TLS_KEY=${TLS_KEY}"
	} > "$WIFI_ENV"
	umask "$umask_old"
	chmod 0600 "$WIFI_ENV"
fi
echo "      done"

# --- 5. system-partition assets (overlay + lower for persistence) -------
# /etc on this device is an overlayfs whose upperdir is tmpfs, so naive
# writes are wiped on reboot. Each file goes to BOTH layers:
#   - overlay (upper, tmpfs): visible to the running session right away.
#   - lower (real ext4):      survives reboot, picked up at next mount.
echo -e "${CYAN}[5/6]${NC} writing systemd assets (overlay + persistent lower)"

WANTS_LINK='/etc/systemd/system/multi-user.target.wants/webinterface-wifi.service'

# --- 5a. overlay writes (immediate effect this session) ---
cp "$SRC_DROPIN" "$NETWORKD_DROPIN" && chmod 0644 "$NETWORKD_DROPIN"
mkdir -p "$(dirname "$MDNS_DROPIN")"
cp "$SRC_MDNS" "$MDNS_DROPIN" && chmod 0644 "$MDNS_DROPIN"
if [ $DO_WIFI -eq 1 ]; then
	cp "$SRC_SERVICE" "$WIFI_SERVICE_UNIT" && chmod 0644 "$WIFI_SERVICE_UNIT"
fi
systemctl daemon-reload
if [ $DO_WIFI -eq 1 ] && [ $DO_ENABLE -eq 1 ]; then
	# Writes the .wants/ symlink into the overlay upper -- volatile.
	systemctl enable webinterface-wifi.service
fi

# --- 5b. persistent writes to the lower (next boot) ---
etc_persist "$SRC_DROPIN" "$NETWORKD_DROPIN" 0644
etc_persist "$SRC_MDNS"   "$MDNS_DROPIN"     0644
if [ $DO_WIFI -eq 1 ]; then
	etc_persist "$SRC_SERVICE" "$WIFI_SERVICE_UNIT" 0644
	if [ $DO_ENABLE -eq 1 ]; then
		# Mirror what `systemctl enable` did, but on the lower.
		etc_persist_symlink "$WIFI_SERVICE_UNIT" "$WANTS_LINK"
	fi
fi
echo "      done"

# --- 6. reload networkd + start proxy ------------------------------------
echo -e "${CYAN}[6/6]${NC} reloading networkd + starting proxy"
{
	echo "version=${WEBINT_RMPP_VERSION}"
	echo "installed_at=$(date -u +%FT%TZ 2>/dev/null || date)"
	echo "wifi_port=${WIFI_PORT}"
	echo "wifi_installed=${DO_WIFI}"
	echo "wifi_user=${WIFI_USER}"
} > "$STATE_FILE"

networkctl reload 2>/dev/null || true
networkctl reconfigure usb1 >/dev/null 2>&1 || true
if [ $DO_WIFI -eq 1 ] && [ $DO_ENABLE -eq 1 ]; then
	systemctl restart webinterface-wifi.service
	sleep 0.5
	if systemctl --quiet is-active webinterface-wifi.service; then
		echo -e "      ${GREEN}wifi proxy active${NC}"
	else
		echo -e "      ${YELLOW}wifi proxy not active -- journalctl -u webinterface-wifi${NC}"
	fi
fi

# --- summary -------------------------------------------------------------
echo
echo -e "${GREEN}install complete${NC}"
echo
echo "  USB web interface: http://10.11.99.1/  (always-on, even without cable)"
if [ $DO_WIFI -eq 1 ]; then
	# Omit :port when it's the scheme default (443 for https).
	portsuffix=":${WIFI_PORT}"
	[ "$WIFI_PORT" -eq 443 ] && portsuffix=''
	wip=$(ip -4 addr show dev wlan0 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
	if [ -n "$wip" ]; then
		echo "  wifi  web interface: https://${wip}${portsuffix}/  (user ${WIFI_USER})"
	else
		echo "  wifi  web interface: https://<wlan0-ip>${portsuffix}/  (no wifi IP right now)"
	fi
fi
echo

if [ $DO_WIFI -eq 1 ]; then
	echo -e "${CYAN}TLS certificate fingerprint (verify on first browser visit):${NC}"
	"$PROXY_BIN" show-cert --cert "$TLS_CERT" 2>/dev/null | grep -E '^(not after|SHA-256|SAN)' | sed 's/^/  /'
	echo
	echo -e "${YELLOW}note:${NC} the cert is self-signed; your browser will warn on first visit."
	echo "      verify the SHA-256 above matches what the browser shows, then 'proceed'"
	echo "      or trust it permanently. See README for trust instructions per OS."
	echo
fi

echo "  status:    webinterface-rmpp status"
echo "  uninstall: bash ${UNINSTALL_FILE}"
echo

if [ $DO_WIFI -eq 1 ] && ! ip -4 addr show | grep -q '10\.11\.99\.1'; then
	echo "note: 10.11.99.1 is not currently assigned -- reboot the device (or plug+"
	echo "      unplug a USB cable once) so the networkd drop-in takes effect on usb1."
fi
