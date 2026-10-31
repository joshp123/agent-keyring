// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/joshp123/agent-keyring/internal/relay"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
)

func main() {
	if err := run(); err != nil {
		slog.Error("relay stopped", "error", err)
		os.Exit(1)
	}
}
func run() error {
	flags := flag.NewFlagSet("agent-keyring-relay", flag.ContinueOnError)
	listen := flags.String("listen", "", "Tailscale IP:port to listen on (required)")
	state := flags.String("state", "", "Private state directory (required)")
	tailscale := flags.String("tailscale", "tailscale", "Path to the Tailscale CLI")
	loopback := flags.Bool("loopback-test", false, "Allow only loopback and use one synthetic node identity for system fixtures")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return err
	}
	if *listen == "" || *state == "" {
		return errors.New("use --listen TAILSCALE_IP:PORT --state DIRECTORY")
	}
	host, _, err := net.SplitHostPort(*listen)
	if err != nil {
		return err
	}
	address, err := netip.ParseAddr(host)
	if err != nil {
		return errors.New("listen must name a literal Tailscale IP")
	}
	if *loopback {
		if !address.IsLoopback() {
			return errors.New("loopback-test requires a loopback address")
		}
	} else if !(netip.MustParsePrefix("100.64.0.0/10").Contains(address) || netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(address)) {
		return errors.New("relay must listen on its Tailscale IP only")
	}
	if err = os.MkdirAll(*state, 0700); err != nil {
		return err
	}
	if err = os.Chmod(*state, 0700); err != nil {
		return err
	}
	certPath, keyPath := filepath.Join(*state, "tls-cert.pem"), filepath.Join(*state, "tls-key.pem")
	if _, err = os.Stat(certPath); errors.Is(err, os.ErrNotExist) {
		if _, keyErr := os.Stat(keyPath); !errors.Is(keyErr, os.ErrNotExist) {
			return errors.New("TLS identity is incomplete; refusing to replace its pin")
		}
		cert, key, err := relaycrypto.NewIdentity("Agent Keyring relay")
		if err != nil {
			return err
		}
		if err = os.WriteFile(keyPath, key, 0600); err != nil {
			return err
		}
		if err = os.WriteFile(certPath, cert, 0600); err != nil {
			return err
		}
	}
	certificate, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return err
	}
	store, err := relay.OpenStore(*state)
	if err != nil {
		return err
	}
	defer store.Close()
	lookup := relay.TailscaleLookup(*tailscale)
	if *loopback {
		lookup = func(_ context.Context, address string) (relay.Node, error) {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return relay.Node{}, err
			}
			ip, err := netip.ParseAddr(host)
			if err != nil || !ip.IsLoopback() {
				return relay.Node{}, errors.New("not loopback")
			}
			return relay.Node{ID: "loopback-fixture", Name: "loopback", Address: address}, nil
		}
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	defer listener.Close()
	fmt.Fprintf(os.Stderr, "Agent Keyring relay listening on %s\n", listener.Addr())
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	return (&relay.Server{Store: store, Certificate: certificate, Lookup: lookup}).Serve(ctx, listener)
}
