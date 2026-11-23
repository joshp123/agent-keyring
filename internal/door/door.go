// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Package door is this computer's door: HTTPS on its Tailscale IP, port
// 17446, with its own TLS key, where Josh's iPhone and Apple Watch answer the
// requests this computer pushed to them (proto/agentkeyring/v2/keyring.proto,
// "Direct: no relay"). It also holds the rule that every connection Agent
// Keyring makes goes to a Tailscale address, never to a name.
//
// Several command processes on one computer share one door: whichever binds
// the port holds it and serves every request of this computer; the others
// try again once a second, so one takes over within a second when the holder
// exits (docs/state-machines.md, "The door").
package door

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"syscall"
	"time"
)

const Port = 17446

var (
	tailnetIPv4 = netip.MustParsePrefix("100.64.0.0/10")
	tailnetIPv6 = netip.MustParsePrefix("fd7a:115c:a1e0::/48")
)

// noTailscale is what Josh's agents are told when this computer has no
// Tailscale address: nothing can reach it, and it can reach nothing.
var noTailscale = errors.New("This computer has no Tailscale address: Tailscale is not installed, not running, or signed out. Agent Keyring reaches the Mac, and the user's iPhone and Apple Watch reach this computer, only over Tailscale. Start Tailscale and sign in, then run this again.")

// testDoor is AGENT_KEYRING_TEST_DOOR: a loopback IP:port that end-to-end
// tests give each stand-in computer in place of its Tailscale IP, or "none"
// for a computer without Tailscale. Anything else in it is refused, so it
// cannot send a login off the tailnet.
func testDoor() (netip.AddrPort, bool, error) {
	text := os.Getenv("AGENT_KEYRING_TEST_DOOR")
	if text == "" {
		return netip.AddrPort{}, false, nil
	}
	if text == "none" {
		return netip.AddrPort{}, true, noTailscale
	}
	address, err := netip.ParseAddrPort(text)
	if err != nil || !address.Addr().IsLoopback() {
		return netip.AddrPort{}, false, errors.New("AGENT_KEYRING_TEST_DOOR must be a loopback IP:port; it exists only for tests")
	}
	return address, true, nil
}

// Testing reports whether this process is an end-to-end test on loopback.
func Testing() bool {
	_, testing, _ := testDoor()
	return testing
}

// Address is where this computer's door is: its Tailscale IP, read now from
// its own interfaces, and port 17446.
func Address() (string, error) {
	if test, testing, err := testDoor(); testing || err != nil {
		if err != nil {
			return "", err
		}
		return test.String(), nil
	}
	addresses, err := net.InterfaceAddrs()
	if err != nil {
		return "", err
	}
	var found netip.Addr
	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err != nil {
			continue
		}
		ip := prefix.Addr().Unmap()
		if tailnetIPv4.Contains(ip) {
			found = ip
			break
		}
		if tailnetIPv6.Contains(ip) && !found.IsValid() {
			found = ip
		}
	}
	if !found.IsValid() {
		return "", noTailscale
	}
	return net.JoinHostPort(found.String(), strconv.Itoa(Port)), nil
}

// CheckHost accepts only a Tailscale IP address (or loopback, in a test), and
// says why it refuses anything else.
func CheckHost(host string) error {
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return fmt.Errorf("%q is a name, not a Tailscale IP address. Agent Keyring reaches other computers only at their Tailscale IP (100.64.0.0/10 or fd7a:115c:a1e0::/48), never by name", host)
	}
	ip = ip.Unmap()
	if tailnetIPv4.Contains(ip) || tailnetIPv6.Contains(ip) || (ip.IsLoopback() && Testing()) {
		return nil
	}
	return fmt.Errorf("%s is not a Tailscale address. Agent Keyring reaches other computers only at their Tailscale IP (100.64.0.0/10 or fd7a:115c:a1e0::/48), so it sent nothing there", ip)
}

// Dialer connects only to a Tailscale address. The check runs on the address
// actually dialled, so nothing is sent if a name resolves elsewhere.
func Dialer() *net.Dialer {
	return &net.Dialer{Timeout: 5 * time.Second, Control: func(_, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		return CheckHost(host)
	}}
}

// Hold serves handler on this computer's door whenever this process can
// bind it: at once if the port is free, else trying again once a second,
// until stop is called. stop waits for answers being taken to finish.
func Hold(ctx context.Context, certificate tls.Certificate, handler http.Handler, held func(address string)) (stop func()) {
	ctx, cancel := context.WithCancel(ctx)
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		for {
			if address, err := Address(); err == nil {
				if listener, err := net.Listen("tcp", address); err == nil {
					if held != nil {
						held(address)
					}
					serve(ctx, listener, certificate, handler)
					return
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
		}
	}()
	return func() { cancel(); <-finished }
}

func serve(ctx context.Context, listener net.Listener, certificate tls.Certificate, handler http.Handler) {
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}}}
	served := make(chan struct{})
	go func() { server.ServeTLS(listener, "", ""); close(served) }()
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	server.Shutdown(shutdown)
	<-served
}
