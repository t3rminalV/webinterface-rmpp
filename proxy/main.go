// webinterface-wifi-proxy -- tiny HTTP(S) reverse proxy with basic-auth
// for the reMarkable Paper Pro's USB web interface.
//
// Subcommands:
//   (default)   run the proxy; reads env LISTEN_ADDR, TARGET, AUTH_USER,
//               AUTH_PASS, TLS_CERT, TLS_KEY (TLS enabled when both set).
//   gen-cert    generate a self-signed ECDSA P-256 cert with given SANs.
//   show-cert   print fingerprint/validity/SANs of an existing cert.
//
// SPDX-License-Identifier: MIT
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const version = "1.0.0"

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envIntOr(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return fallback
}

// --- rate limiter -------------------------------------------------------
// Tracks failed auths per source IP in a sliding window. After `limit`
// failures within `window`, the IP is blocked for `block`. Constant
// memory under sustained scanning because successful auth (or window
// expiry) clears the entry. All operations are O(1) under the lock.
type rateLimiter struct {
	mu      sync.Mutex
	entries map[string]*rlEntry
	limit   int
	window  time.Duration
	block   time.Duration
}

type rlEntry struct {
	failures     int
	windowStart  time.Time
	blockedUntil time.Time
}

func newRateLimiter(limit int, window, block time.Duration) *rateLimiter {
	return &rateLimiter{
		entries: make(map[string]*rlEntry),
		limit:   limit, window: window, block: block,
	}
}

// blockedUntil returns the time the IP is blocked until, or zero time if
// not blocked right now.
func (r *rateLimiter) blockedUntil(ip string) time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	e := r.entries[ip]
	if e == nil || time.Now().After(e.blockedUntil) {
		return time.Time{}
	}
	return e.blockedUntil
}

func (r *rateLimiter) recordFailure(ip string) (blockedNow bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	e := r.entries[ip]
	if e == nil {
		e = &rlEntry{windowStart: now}
		r.entries[ip] = e
	}
	if now.Sub(e.windowStart) > r.window {
		e.windowStart = now
		e.failures = 1
	} else {
		e.failures++
	}
	if e.failures >= r.limit && now.After(e.blockedUntil) {
		e.blockedUntil = now.Add(r.block)
		return true
	}
	return false
}

func (r *rateLimiter) recordSuccess(ip string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.entries, ip)
}

// hostOnly extracts the host part of "ip:port" (also works for "[ipv6]:port").
func hostOnly(addr string) string {
	h, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return h
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "gen-cert":
			if err := genCert(os.Args[2:]); err != nil {
				log.Fatalf("gen-cert: %v", err)
			}
			return
		case "show-cert":
			if err := showCert(os.Args[2:]); err != nil {
				log.Fatalf("show-cert: %v", err)
			}
			return
		case "version", "--version", "-v":
			fmt.Println(version)
			return
		case "help", "--help", "-h":
			usage()
			return
		}
	}
	runProxy()
}

func usage() {
	fmt.Fprintf(os.Stderr, `webinterface-wifi-proxy %s

usage:
  webinterface-wifi-proxy                 run the proxy (reads env)
  webinterface-wifi-proxy gen-cert ...    generate self-signed cert+key
  webinterface-wifi-proxy show-cert ...   inspect a cert
  webinterface-wifi-proxy version

env (proxy mode):
  LISTEN_ADDR        default :443
  LISTEN_DEVICE      optional; bind to that interface's IPv4 only.
  TARGET             default 10.11.99.1:80
  AUTH_USER          required
  AUTH_PASS          required
  TLS_CERT           required -- PEM certificate path
  TLS_KEY            required -- PEM private key path
  AUTH_FAIL_LIMIT    failed auths before blocking         (default 5)
  AUTH_FAIL_WINDOW   sliding window in seconds            (default 60)
  AUTH_FAIL_BLOCK    block duration in seconds            (default 300)
`, version)
}

// --- proxy mode ---------------------------------------------------------

func runProxy() {
	target := envOr("TARGET", "10.11.99.1:80")
	user := os.Getenv("AUTH_USER")
	pass := os.Getenv("AUTH_PASS")
	realm := envOr("AUTH_REALM", "reMarkable Paper Pro")
	tlsCert := os.Getenv("TLS_CERT")
	tlsKey := os.Getenv("TLS_KEY")

	if user == "" || pass == "" {
		log.Fatal("AUTH_USER and AUTH_PASS must both be set (no anonymous mode)")
	}
	if tlsCert == "" || tlsKey == "" {
		log.Fatal("TLS_CERT and TLS_KEY are required (HTTPS-only -- no plain-HTTP mode)")
	}

	listenAddr := envOr("LISTEN_ADDR", ":443")

	// If LISTEN_DEVICE is set and the addr has no host part, rebind to
	// that device's IPv4 specifically. Leaving LISTEN_DEVICE empty is
	// the recommended default -- the proxy then survives wifi-IP changes.
	if dev := os.Getenv("LISTEN_DEVICE"); dev != "" {
		host, port, err := net.SplitHostPort(listenAddr)
		if err != nil {
			log.Fatalf("bad LISTEN_ADDR %q: %v", listenAddr, err)
		}
		if host == "" {
			ip, err := waitForIPv4(dev, 60*time.Second)
			if err != nil {
				log.Fatalf("LISTEN_DEVICE=%s: %v", dev, err)
			}
			listenAddr = net.JoinHostPort(ip.String(), port)
			log.Printf("LISTEN_DEVICE=%s -> binding to %s", dev, listenAddr)
		}
	}

	upstream, err := url.Parse("http://" + target)
	if err != nil {
		log.Fatalf("bad TARGET %q: %v", target, err)
	}

	rp := httputil.NewSingleHostReverseProxy(upstream)
	rp.ErrorLog = log.New(os.Stderr, "proxy: ", log.LstdFlags)
	rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("upstream error: %v", err)
		http.Error(w, "bad gateway: upstream unreachable", http.StatusBadGateway)
	}

	expectUser := []byte(user)
	expectPass := []byte(pass)

	rl := newRateLimiter(
		envIntOr("AUTH_FAIL_LIMIT", 5),
		time.Duration(envIntOr("AUTH_FAIL_WINDOW", 60))*time.Second,
		time.Duration(envIntOr("AUTH_FAIL_BLOCK", 300))*time.Second,
	)
	log.Printf("auth rate limit: %d failures / %s -> block %s",
		rl.limit, rl.window, rl.block)

	gated := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		srcIP := hostOnly(r.RemoteAddr)

		// Already blocked? Return 429 with Retry-After so well-behaved
		// clients back off. Don't disclose user existence either way.
		if until := rl.blockedUntil(srcIP); !until.IsZero() {
			retry := int(time.Until(until).Seconds()) + 1
			w.Header().Set("Retry-After", strconv.Itoa(retry))
			http.Error(w, "too many failed auth attempts", http.StatusTooManyRequests)
			return
		}

		u, p, ok := r.BasicAuth()
		if !ok {
			challenge(w, realm)
			return
		}
		uOK := subtle.ConstantTimeCompare([]byte(u), expectUser) == 1
		pOK := subtle.ConstantTimeCompare([]byte(p), expectPass) == 1
		if !(uOK && pOK) {
			if rl.recordFailure(srcIP) {
				log.Printf("blocked %s for %s after %d auth failures",
					srcIP, rl.block, rl.limit)
			} else {
				log.Printf("auth failure from %s for user %q", r.RemoteAddr, u)
			}
			challenge(w, realm)
			return
		}
		rl.recordSuccess(srcIP)
		r.Header.Del("Authorization")
		rp.ServeHTTP(w, r)
	})

	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           gated,
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	log.Printf("webinterface-wifi-proxy %s listening on https://%s -> http://%s (auth user=%q)",
		version, listenAddr, target, user)
	if err := srv.ListenAndServeTLS(tlsCert, tlsKey); err != nil {
		log.Fatal(err)
	}
}

// waitForIPv4 polls until the named interface has an IPv4 address, or
// the deadline elapses. Handles the boot race where the proxy service
// starts before wlan0 has finished DHCP.
func waitForIPv4(dev string, timeout time.Duration) (net.IP, error) {
	deadline := time.Now().Add(timeout)
	logged := false
	for {
		iface, err := net.InterfaceByName(dev)
		if err == nil {
			addrs, _ := iface.Addrs()
			for _, a := range addrs {
				ipnet, ok := a.(*net.IPNet)
				if !ok {
					continue
				}
				if ip4 := ipnet.IP.To4(); ip4 != nil && !ip4.IsLinkLocalUnicast() {
					return ip4, nil
				}
			}
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("no IPv4 on %s after %s (is wifi up?)", dev, timeout)
		}
		if !logged {
			log.Printf("waiting for IPv4 on %s...", dev)
			logged = true
		}
		time.Sleep(2 * time.Second)
	}
}

func challenge(w http.ResponseWriter, realm string) {
	w.Header().Set("WWW-Authenticate", `Basic realm="`+realm+`", charset="UTF-8"`)
	http.Error(w, "authentication required", http.StatusUnauthorized)
}

// --- gen-cert subcommand ------------------------------------------------

func genCert(args []string) error {
	fs := flag.NewFlagSet("gen-cert", flag.ExitOnError)
	certPath := fs.String("cert", "cert.pem", "output certificate path")
	keyPath := fs.String("key", "key.pem", "output key path (mode 0600)")
	sans := fs.String("san", "", "comma-separated SAN entries (IPs or DNS names)")
	days := fs.Int("days", 3650, "validity in days (default ~10 years)")
	cn := fs.String("cn", "reMarkable Paper Pro", "Subject CommonName")
	_ = fs.Parse(args)

	var ips []net.IP
	var dns []string
	seen := map[string]bool{}
	for _, s := range strings.Split(*sans, ",") {
		s = strings.TrimSpace(s)
		if s == "" || seen[s] {
			continue
		}
		seen[s] = true
		if ip := net.ParseIP(s); ip != nil {
			ips = append(ips, ip)
		} else {
			dns = append(dns, s)
		}
	}
	if len(ips) == 0 && len(dns) == 0 {
		return fmt.Errorf("--san is required (at least one IP or DNS name)")
	}

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate key: %w", err)
	}

	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialLimit)
	if err != nil {
		return fmt.Errorf("generate serial: %w", err)
	}

	notBefore := time.Now().Add(-1 * time.Hour) // tolerate small clock skew
	notAfter := notBefore.Add(time.Duration(*days) * 24 * time.Hour)

	tmpl := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: *cn},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IPAddresses:           ips,
		DNSNames:              dns,
	}

	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		return fmt.Errorf("create cert: %w", err)
	}

	if err := writePEM(*certPath, 0644, "CERTIFICATE", der); err != nil {
		return err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return fmt.Errorf("marshal key: %w", err)
	}
	if err := writePEM(*keyPath, 0600, "PRIVATE KEY", keyDER); err != nil {
		return err
	}

	fmt.Printf("wrote %s (valid until %s)\n", *certPath, notAfter.UTC().Format(time.RFC3339))
	fmt.Printf("wrote %s (mode 0600)\n", *keyPath)
	if len(ips) > 0 {
		fmt.Printf("SAN ips:  %v\n", ips)
	}
	if len(dns) > 0 {
		fmt.Printf("SAN dns:  %v\n", dns)
	}
	// SHA-256 fingerprint for the user to verify out-of-band.
	sum := sha256.Sum256(der)
	fmt.Printf("SHA-256:  %s\n", colonHex(sum[:]))
	return nil
}

func writePEM(path string, mode os.FileMode, blockType string, der []byte) error {
	// O_TRUNC is intentional -- overwrite stale cert/key cleanly.
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()
	if err := pem.Encode(f, &pem.Block{Type: blockType, Bytes: der}); err != nil {
		return fmt.Errorf("encode %s: %w", path, err)
	}
	// Re-apply mode in case umask narrowed it for cert (0644 desired).
	return os.Chmod(path, mode)
}

// --- show-cert subcommand -----------------------------------------------

func showCert(args []string) error {
	fs := flag.NewFlagSet("show-cert", flag.ExitOnError)
	certPath := fs.String("cert", "cert.pem", "certificate file to inspect")
	_ = fs.Parse(args)

	pemBytes, err := os.ReadFile(*certPath)
	if err != nil {
		return err
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil || block.Type != "CERTIFICATE" {
		return fmt.Errorf("no CERTIFICATE PEM block found in %s", *certPath)
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return err
	}
	sum := sha256.Sum256(cert.Raw)
	fmt.Printf("subject:      %s\n", cert.Subject)
	fmt.Printf("issuer:       %s\n", cert.Issuer)
	fmt.Printf("not before:   %s\n", cert.NotBefore.UTC().Format(time.RFC3339))
	fmt.Printf("not after:    %s\n", cert.NotAfter.UTC().Format(time.RFC3339))
	now := time.Now()
	switch {
	case now.Before(cert.NotBefore):
		fmt.Println("status:       NOT YET VALID")
	case now.After(cert.NotAfter):
		fmt.Println("status:       EXPIRED")
	default:
		left := cert.NotAfter.Sub(now)
		fmt.Printf("status:       valid (%d days left)\n", int(left.Hours()/24))
	}
	if len(cert.IPAddresses) > 0 {
		fmt.Printf("SAN ips:      %v\n", cert.IPAddresses)
	}
	if len(cert.DNSNames) > 0 {
		fmt.Printf("SAN dns:      %v\n", cert.DNSNames)
	}
	fmt.Printf("sig alg:      %s\n", cert.SignatureAlgorithm)
	fmt.Printf("SHA-256:      %s\n", colonHex(sum[:]))
	return nil
}

func colonHex(b []byte) string {
	hexStr := hex.EncodeToString(b)
	var sb strings.Builder
	for i := 0; i < len(hexStr); i += 2 {
		if i > 0 {
			sb.WriteByte(':')
		}
		sb.WriteString(strings.ToUpper(hexStr[i : i+2]))
	}
	return sb.String()
}
