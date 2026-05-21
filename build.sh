#!/usr/bin/env bash
# build.sh -- cross-compile the Go proxy for linux/arm64, assemble a
# distributable tarball, and a directory copy. Run on the dev machine.
# SPDX-License-Identifier: MIT
set -eu
cd "$(dirname "$0")"

VERSION="$(awk -F"'" '/^WEBINT_RMPP_VERSION=/{print $2; exit}' webinterface-rmpp)"
PKG="webinterface-rmpp-${VERSION}"
DIST_DIR="dist/${PKG}"

echo ">> version: ${VERSION}"
echo ">> dist:    ${DIST_DIR}"

# 1. cross-compile the proxy
echo ">> building proxy binary (linux/arm64, static, stripped)..."
(
	cd proxy
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
		go build -ldflags='-s -w' -trimpath -o ../bin/webinterface-wifi-proxy ./...
)
file bin/webinterface-wifi-proxy | grep -q 'ARM aarch64' \
	|| { echo "ERROR: proxy binary is not ARM aarch64" >&2; exit 1; }
size=$(wc -c < bin/webinterface-wifi-proxy | tr -d ' ')
echo "   $(du -h bin/webinterface-wifi-proxy | cut -f1) (${size} bytes)"

# 2. assemble dist dir
echo ">> staging tarball..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/units"
cp install.sh uninstall.sh webinterface-rmpp README.md "$DIST_DIR/"
cp bin/webinterface-wifi-proxy "$DIST_DIR/"
cp units/05-webinterface-alwayson.network "$DIST_DIR/units/"
cp units/webinterface-wifi.service        "$DIST_DIR/units/"
mkdir -p "$DIST_DIR/units/25-wlan0.network.d"
cp units/25-wlan0.network.d/10-webinterface-mdns.conf "$DIST_DIR/units/25-wlan0.network.d/"
chmod 0755 "$DIST_DIR/install.sh" \
           "$DIST_DIR/uninstall.sh" \
           "$DIST_DIR/webinterface-rmpp" \
           "$DIST_DIR/webinterface-wifi-proxy"

# 3. tarball
tarball="dist/${PKG}.tar.gz"
( cd dist && tar czf "${PKG}.tar.gz" "${PKG}" )
echo
echo ">> built:"
echo "   ${tarball}  ($(du -h "$tarball" | cut -f1))"
echo "   ${DIST_DIR}/"
echo
echo "deploy:"
echo "   scp ${tarball} root@<rmpp-ip>:/home/root/"
echo "   ssh root@<rmpp-ip> 'tar xzf /home/root/${PKG}.tar.gz -C /home/root/ && bash /home/root/${PKG}/install.sh'"
