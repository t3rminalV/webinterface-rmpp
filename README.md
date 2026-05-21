![Static Badge](https://img.shields.io/badge/Paper%20Pro-supported-green)
![Static Badge](https://img.shields.io/badge/arch-aarch64-blue)
![Static Badge](https://img.shields.io/badge/TLS-self--signed-yellow)
![Static Badge](https://img.shields.io/badge/auth-basic-orange)

# webinterface-rmpp

This program will convince the reMarkable Paper Pro to keep the
[USB Web Interface](http://10.11.99.1) running whether or not a USB
cable is plugged in, and additionally expose it on the wifi network
through a tiny reverse proxy that terminates HTTPS and enforces HTTP
basic authentication.

Useful if you want to drop files onto the device from your laptop or
phone without going via the cable, the cloud, or a third-party app.

## Compatibility

- ✅ Remarkable Paper Pro
- ❌ RM1, RM2. This hasnt been tested on the Paper Pure or Paper Pro Move
as I do not have access to these devices

### How it differs from what already exists on the device

By default the Paper Pro's USB web interface only runs while a host
computer is plugged into the USB-C port: when the cable comes out,
`systemd-networkd` notices `usb1` lose carrier, tears the
`10.11.99.1/27` address back down, and xochitl drops the web interface.
This tool flips two `systemd-networkd` directives so the address stays
configured regardless of cable state, then adds an HTTPS/basic-auth
reverse proxy bound to `wlan0`.

---

### Install

`$ scp webinterface-rmpp-<version>.tar.gz root@<paper-pro-ip>:/home/root/`

`$ ssh root@<paper-pro-ip>`

`$ tar xzf /home/root/webinterface-rmpp-<version>.tar.gz -C /home/root/`

`$ cd /home/root/webinterface-rmpp-<version>`

`$ bash install.sh`

You'll be prompted for a wifi-proxy username and password. The installer
generates a self-signed TLS certificate with a sensible SAN list (the
device hostname, `*.local`, `localhost`, `10.11.99.1`, current wlan0
IPv4) and prints the certificate's SHA-256 fingerprint — write it down,
you'll want it on first browser visit.

For non-interactive installs:

`$ bash install.sh --wifi-user <name> --wifi-pass <password> --wifi-port 443`

The proxy is **HTTPS-only** — there is no plain-HTTP mode. The default
port is **443**. The proxy listens on all interfaces (`0.0.0.0:443`)
so it picks up wifi IP changes (DHCP renewals, switching networks)
automatically — no restart needed.

### Connecting after install

After install you can reach the wifi proxy at either:

- `https://<wlan0-ip>/` — works everywhere; IP shown by
  `webinterface-rmpp status`.
- `https://<hostname>.local/` — e.g. `https://imx8mm-ferrari.local/`.
  Works on any client that does mDNS (macOS, recent Linux with
  `systemd-resolved` or Avahi, iOS). The installer enables mDNS
  advertising on `wlan0` and the cert SANs include `<hostname>.local`,
  so this URL validates against the same cert as the IP form.

Some captive-portal / corporate wifi networks block multicast and break
mDNS. If `.local` doesn't resolve, fall back to the bare IP — both URLs
point at the same proxy.

### Remove

`$ bash /home/root/.local/share/webinterface-rmpp/uninstall.sh`

Pass `--keep-config` to preserve `wifi.env` (your credentials) and the
generated TLS cert/key for a later re-install.

## Build (on your dev machine)

The tarball is produced by a single build script that cross-compiles
the Go proxy for `linux/arm64` and assembles everything into
`dist/webinterface-rmpp-<version>.tar.gz`. Requires Go ≥ 1.21:

```
$ bash build.sh
```

## Usage

### CLI command reference

| Command                              | What it does                                                  |
| ------------------------------------ | ------------------------------------------------------------- |
| `webinterface-rmpp status`           | Health check: USB interface, `usb1` IP, drop-in, xochitl.conf, wifi proxy, cert expiry, reachable URL |
| `webinterface-rmpp ensure`           | Re-assert `WebInterfaceEnabled=true` + reload networkd        |
| `webinterface-rmpp logs [-n N] [-f]` | Tail the proxy's journal (`-f` to follow)                     |
| `webinterface-rmpp diag`             | Full debug report (mounts, units, configs, journal) to stdout |
| `webinterface-rmpp enable-wifi`      | Enable + start the wifi proxy                                 |
| `webinterface-rmpp disable-wifi`     | Stop + disable the wifi proxy                                 |
| `webinterface-rmpp restart-wifi`     | Restart (e.g. after editing `wifi.env`)                       |
| `webinterface-rmpp set-wifi-port N`  | Change the listen port (default `443`)                        |
| `webinterface-rmpp set-wifi-auth`    | Interactively change basic-auth username/password             |
| `webinterface-rmpp show-wifi-auth`   | Print the current username (not the password)                 |
| `webinterface-rmpp regen-cert [SAN…]`| Regenerate the self-signed cert; extra SANs accepted          |
| `webinterface-rmpp show-cert`        | Subject / SANs / validity / SHA-256 fingerprint               |
| `webinterface-rmpp print-trust-snippet` | Copy-paste commands to trust the cert on macOS/Linux/Windows/iOS |

Detailed notes below for the ones worth elaborating.

### To use webinterface-rmpp, run:

`$ systemctl enable webinterface-wifi`

This is done automatically by the installer; you only need it again if
you've previously disabled the service.

### To stop using webinterface-rmpp's wifi proxy, run:

`$ webinterface-rmpp disable-wifi`

The "always-on USB" piece is declarative `systemd-networkd` config and
needs no service of its own.

### Status

`$ webinterface-rmpp status`

This prints whether the web interface is listening, whether `usb1` has
the address, the state of the systemd-networkd drop-in, whether
xochitl's `WebInterfaceEnabled` is `true`, and the wifi proxy's state
plus its full URL.

### Change the wifi port

`$ webinterface-rmpp set-wifi-port 9443`

Anything from 1 to 65535. Privileged ports work because the service
runs as root. **Don't pick port 80** — it'll collide with xochitl on
`10.11.99.1:80` unless you also set `LISTEN_DEVICE=wlan0` in
`wifi.env` (which freezes the listen IP and means DHCP changes need a
restart). `443` is the default and has no such conflict.

### Change the wifi proxy credentials

`$ webinterface-rmpp set-wifi-auth`

(Interactive; passwords are echoed hidden.) Pass username and password
as positional arguments to skip the prompts.

### Tail the proxy's logs

`$ webinterface-rmpp logs           # last 50 lines`

`$ webinterface-rmpp logs -n 200    # last 200 lines`

`$ webinterface-rmpp logs -f        # follow (live tail)`

### Collect a debug report

`$ webinterface-rmpp diag > /home/root/rmpp-diag.txt`

Bundles mount layout, every networkd file, `usb0`/`usb1` state, the
`xochitl.conf` toggle, service status, cert info, listening ports, and
the last 50 journal lines into one self-contained text file you can
`scp` off the device. `AUTH_PASS` is redacted.

### Inspect the TLS certificate

`$ webinterface-rmpp show-cert`

Prints the subject, issuer, validity window, SAN list, signature
algorithm, and the SHA-256 fingerprint — match this against what your
browser shows on the security warning page to verify the cert is yours.

### Re-generate the TLS certificate

`$ webinterface-rmpp regen-cert`

Useful if your wifi IP has changed, the cert is approaching expiry, or
you want to add an extra SAN:

`$ webinterface-rmpp regen-cert my-tablet.lan 10.0.0.42`

## SSL / Certificate Trust

On first visit the browser will show a "Not Secure" warning because the
certificate is self-signed. You have three reasonable options:

### Verify and accept on first visit

Compare the SHA-256 fingerprint the browser displays under the warning
to the one printed by `webinterface-rmpp show-cert`. If they match,
nothing is intercepting your connection; click through and the browser
will remember the cert for that hostname.

### Trust the cert permanently on your devices

Easiest path — let the device print the copy-paste commands for you:

`$ webinterface-rmpp print-trust-snippet`

It outputs the fingerprint plus ready-to-paste snippets for macOS,
Debian/Ubuntu, Fedora/RHEL, Windows (PowerShell) and iOS/iPadOS.

Or do it by hand — copy the cert off the device:

`$ scp root@<paper-pro-ip>:/home/root/.config/webinterface-rmpp/tls/cert.pem ./rmpp-cert.pem`

- **macOS:** open the file in Keychain Access → drag into "System" →
  double-click the entry, expand "Trust", set *Always Trust*.
- **Linux:** `sudo cp rmpp-cert.pem /usr/local/share/ca-certificates/rmpp.crt && sudo update-ca-certificates`
- **Windows:** import via `certmgr.msc` under *Trusted Root
  Certification Authorities*.
- **iOS / iPadOS:** AirDrop or email yourself the `.pem`, install the
  profile via *Settings → General → VPN & Device Management*, then
  enable trust under *Settings → General → About → Certificate Trust
  Settings*.

### Use your own certificate

Drop a real cert + key (e.g. one issued by your private CA, or a
Let's Encrypt cert obtained via DNS-01) onto the device, then point
the env vars at it:

```
$ nano /home/root/.config/webinterface-rmpp/wifi.env
# set:
#   TLS_CERT=/path/to/fullchain.pem
#   TLS_KEY=/path/to/key.pem
$ webinterface-rmpp restart-wifi
```

## How Does It Work?

### Definitions

**USB Web Interface:** the server xochitl runs on `10.11.99.1:80` that
serves the file browser and accepts uploads.

**usb0 / usb1:** the two USB gadget ethernet functions the reMarkable
exposes. `usb0` is the host-facing interface that comes up when a USB
cable is connected to a computer; `usb1` is the cable-independent
fallback. By default the Paper Pro's `systemd-networkd` config
(`/etc/systemd/network/10-usb.network`) assigns `10.11.99.1/27` to
whichever has carrier, and serves DHCP from there.

**xochitl:** the reMarkable reader/writer binary at `/usr/bin/xochitl`.
Starts the USB web interface on whichever `usb*` interface has the IP
when it starts.

**wlan0:** the wifi network interface.

### Always-on USB web interface

By default `usb1` only gets its IP while a cable is connected: the
stock `10-usb.network` does not set `ConfigureWithoutCarrier=yes` or
`IgnoreCarrierLoss=yes`, so networkd removes the address as soon as
carrier drops, and xochitl follows by dropping the web interface.

This tool installs a higher-priority `systemd-networkd` configuration
that matches `usb1` only, replicates the stock settings (`Address`,
`DHCPServer`, etc.), and adds the two cable-independent directives.
Because the new file sorts before the stock `10-usb.network`, networkd
picks it for `usb1` and the address now persists regardless of cable
state.

#### Before (stock `10-usb.network`, applies to all `usb*`)

```ini
[Network]
Address=10.11.99.1/27
DHCPServer=yes
```

`usb1` gets the address only while carrier is present.

#### After (new `05-webinterface-alwayson.network`, matches `usb1`)

```ini
[Match]
Name=usb1

[Network]
Address=10.11.99.1/27
ConfigureWithoutCarrier=yes
IgnoreCarrierLoss=yes
KeepConfiguration=yes
DHCPServer=yes
```

`usb1` keeps `10.11.99.1` whether or not a cable is plugged in. xochitl
finds it on startup and the web interface stays up. `usb0` is left
alone, so cable-based USB SSH and DHCP to the host computer continue to
work unchanged.

### Wifi reverse proxy

`xochitl` only binds the web interface to `10.11.99.1:80` — it never
listens on `wlan0`. To reach the interface over wifi, a tiny static Go
binary listens on `0.0.0.0:<port>` and forwards each authenticated
request to `10.11.99.1:80`.

The proxy uses port **443**, so it can bind `0.0.0.0` without
colliding with xochitl on `10.11.99.1:80`. Binding to all interfaces
means the listener is independent of which IPv4 `wlan0` happens to
have, so DHCP renewals and joining a new wifi network Just Work — no
restart needed.

If you want to restrict the listener to a specific interface, set
`LISTEN_DEVICE=wlan0` in `wifi.env`; the proxy will then resolve that
interface's IPv4 at start (with a retry loop while wifi comes up). The
trade-off is that subsequent IP changes will need a
`webinterface-rmpp restart-wifi`.

#### Pseudo code

```
on every incoming request r on wlan0:<port>:
    user, pass = r.BasicAuth()
    if not user or not pass:
        respond 401 with WWW-Authenticate: Basic realm="reMarkable Paper Pro"
        return
    if constant_time_compare(user, AUTH_USER) and
       constant_time_compare(pass, AUTH_PASS):
        del r.Authorization
        forward r to http://10.11.99.1:80
    else:
        log "auth failure from <ip> for user <user>"
        respond 401
```

`AUTH_USER` and `AUTH_PASS` are read from
`/home/root/.config/webinterface-rmpp/wifi.env` (mode `0600`). The
proxy refuses to start if either is empty — there is no "anonymous
mode" by design.

### TLS

TLS is mandatory — the proxy refuses to start if `TLS_CERT` and
`TLS_KEY` aren't both set in `wifi.env`. Connections are served with
`ListenAndServeTLS` (minimum TLS 1.2). The installer generates a
self-signed ECDSA P-256 cert valid for ten years, with the following
Subject Alternative Names:

```
DNS:  <hostname>, <hostname>.local, localhost, remarkable.local
IP:   127.0.0.1, 10.11.99.1, <current wlan0 IPv4 if present>
```

Additional SANs can be requested at install time with `--san`, or added
later with `regen-cert`. Bring-your-own certificates work too — just
point the env vars at them.

## Files installed

```
/etc/systemd/network/05-webinterface-alwayson.network
    Higher-priority drop-in matching usb1 only; always-on directives.

/etc/systemd/network/25-wlan0.network.d/10-webinterface-mdns.conf
    Drop-in for the stock wlan0 network -- enables MulticastDNS=yes so
    https://<hostname>.local/ resolves.

/etc/systemd/system/webinterface-wifi.service
    systemd unit that runs the proxy binary with EnvironmentFile= set
    to the wifi.env below.

/home/root/.local/bin/webinterface-rmpp
    The CLI ('status', 'logs', 'diag', 'regen-cert', etc).

/home/root/.local/bin/webinterface-wifi-proxy
    Static aarch64 Go binary: the proxy itself, plus 'gen-cert' and
    'show-cert' subcommands.

/home/root/.config/webinterface-rmpp/wifi.env       (mode 0600)
    LISTEN_ADDR, LISTEN_DEVICE, TARGET,
    AUTH_USER, AUTH_PASS, TLS_CERT, TLS_KEY,
    AUTH_FAIL_LIMIT, AUTH_FAIL_WINDOW, AUTH_FAIL_BLOCK   (optional)

/home/root/.config/webinterface-rmpp/tls/cert.pem   (mode 0644)
/home/root/.config/webinterface-rmpp/tls/key.pem    (mode 0600)
    Self-signed certificate and its private key.

/home/root/.local/share/webinterface-rmpp/uninstall.sh
```

#### Tunable env vars in `wifi.env`

Most users won't need to touch these. Edit `wifi.env` then
`webinterface-rmpp restart-wifi` to apply.

| Variable           | Default     | What it does                                          |
| ------------------ | ----------- | ----------------------------------------------------- |
| `LISTEN_ADDR`      | `:443`      | Address:port the proxy binds to                       |
| `LISTEN_DEVICE`    | *(empty)*   | If set (e.g. `wlan0`), bind that interface's IP only — freezes listener IP, restart on DHCP change |
| `TARGET`           | `10.11.99.1:80` | Upstream xochitl URL                              |
| `AUTH_USER`        | `admin`     | Basic-auth username                                   |
| `AUTH_PASS`        | *(prompted at install)* | Basic-auth password                       |
| `TLS_CERT`         | `…/tls/cert.pem` | Server certificate path                          |
| `TLS_KEY`          | `…/tls/key.pem`  | Server private key path                          |
| `AUTH_FAIL_LIMIT`  | `5`         | Failed auths in window before blocking the source IP  |
| `AUTH_FAIL_WINDOW` | `60`        | Sliding window in seconds                             |
| `AUTH_FAIL_BLOCK`  | `300`       | Block duration in seconds                             |

Plus the idempotent edit of `WebInterfaceEnabled=true` in
`/home/root/.config/remarkable/xochitl.conf` (with a `.bak` left
beside it).

**Nothing else on `/` is touched. The xochitl binary is not modified.**

### Persistence and the `/etc` overlay

The Paper Pro mounts `/etc` as an **overlayfs** whose upperdir is on
**tmpfs** (`/var/volatile/etc`):

```
overlay on /etc type overlay (rw,...,lowerdir=/etc,upperdir=/var/volatile/etc,...)
```

That means any naive write to `/etc/whatever` lands in tmpfs and is
**wiped at every reboot**. The lower of the overlay — the real `/etc`
on the read-only root partition — is what survives, and that's where
boot-time config has to live for systemd to find it on the next boot.

This tool writes each `/etc` file **twice**:

1. To the overlay (`/etc/...` directly) — so the current session sees
   the change and `systemctl daemon-reload` / `systemctl enable` work
   straight away.
2. To the underlying ext4 (the lower) — by mounting the root block
   device (`/dev/mmcblk0p3`) a **second time** at `/run/webint-rmpp-lower`.
   The second mount shares the same ext4 superblock as `/` but has no
   `/etc` overlay layered on top of it, so writes under
   `/run/webint-rmpp-lower/etc/...` go straight to the persistent
   partition. The mountpoint is removed once the write is done.

   (An earlier version of this used `unshare --mount` + `umount /etc`
   inside a private mount namespace, but `unshare` isn't part of every
   Paper Pro BusyBox build — the second-mount trick has no such
   dependency.)

After a reboot the tmpfs upper is empty again, the overlay shows the
lower, and our files appear naturally. `/home` (the encrypted disk)
isn't overlay'd, so the CLI, proxy binary, cert, key and credentials
need no special treatment.

After a **firmware OTA** update the entire root partition is reflashed
and the lower's copies are gone too; re-run `install.sh` to put them
back. Everything in `/home` still survives.

## When the device is asleep

The Paper Pro suspends aggressively. A sleeping device drops the wifi
association and stops responding on the USB gadget, so both the wifi
proxy and the USB web interface will appear "broken" until you briefly 
press the power button or wake up the device. This is normal device
behaviour, not a configuration problem — `webinterface-rmpp status`
run over wifi from a sleeping rMPP will fail to connect, and SSH over
the cable from your laptop will hang during the handshake.

If the device is awake and you still can't reach either interface,
*then* it's worth digging into the diagnostics.

## Security model

What the proxy gives you:

- **HTTPS** with a self-signed ECDSA P-256 cert — eavesdroppers on the
  same wifi can't read your traffic or recover your password.
- **HTTP basic authentication** with a constant-time password compare —
  nobody can browse your files without the password.
- **Auth-failure rate limiting**: 5 failed attempts within 60 seconds
  blocks the source IP for 5 minutes (configurable via `AUTH_FAIL_LIMIT`
  / `AUTH_FAIL_WINDOW` / `AUTH_FAIL_BLOCK` in `wifi.env`). The block is
  in-memory, scoped per source IP, and clears on a successful auth.
- **`BindToDevice`-style isolation:** the proxy binds to `wlan0` only,
  not the USB interfaces, so cable-connected hosts can't accidentally
  hit it.

What it doesn't give you:

- A certificate any browser trusts out-of-the-box. Verify the
  fingerprint and trust the cert, or replace it with one signed by a
  real CA.
- Protection if the proxy's private key is exfiltrated. The key lives
  on the encrypted `/home` filesystem with mode `0600`, but treat it
  the way you would any long-lived TLS key.

For higher-assurance access prefer an SSH tunnel:

```
$ ssh -L 8888:10.11.99.1:80 root@<paper-pro-ip>
$ open http://localhost:8888/
```

## License

MIT.
