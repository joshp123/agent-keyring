// Written by AI on 2026.11.27 by model gpt-6.2-sol.

// test-apns receives APNs POSTs over loopback TLS for end-to-end tests.
// It writes each raw payload to DIR/pushes/<hex device token>/*.json.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func main() {
	dir := flag.String("dir", "", "Directory for apple-ca.pem and recorded pushes")
	listen := flag.String("listen", "127.0.0.1:0", "Loopback IP:PORT")
	flag.Parse()

	if err := runTestPushGateway(*dir, *listen); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runTestPushGateway(dir, listen string) error {
	server, listener, caPath, err := prepareServer(dir, listen)
	if err != nil {
		return err
	}
	// ServeTLS owns the listener once called.
	if _, err := fmt.Printf("test-apns ready https://%s %s\n", listener.Addr(), caPath); err != nil {
		return errors.Join(err, listener.Close())
	}
	return server.ServeTLS(listener, "", "")
}

func prepareServer(dir, listen string) (*http.Server, net.Listener, string, error) {
	address, err := netip.ParseAddrPort(listen)
	if err != nil || !address.Addr().IsLoopback() {
		return nil, nil, "", errors.New("--listen must be a loopback IP:PORT")
	}
	if dir == "" {
		return nil, nil, "", errors.New("--dir is required")
	}
	dir, err = filepath.Abs(dir)
	if err != nil {
		return nil, nil, "", err
	}
	cert, ca, err := generateTestGatewayCertificate(address.Addr())
	if err != nil {
		return nil, nil, "", err
	}
	listener, err := net.ListenTCP("tcp", net.TCPAddrFromAddrPort(address))
	if err != nil {
		return nil, nil, "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, "", errors.Join(err, listener.Close())
	}
	caPath := filepath.Join(dir, "apple-ca.pem")
	if err := os.WriteFile(caPath, ca, 0o600); err != nil {
		return nil, nil, "", errors.Join(err, listener.Close())
	}

	mux := http.NewServeMux()
	receive := receivePush(dir)
	mux.HandleFunc("POST /3/device/{token}", receive)
	mux.HandleFunc("POST /sandbox/3/device/{token}", receive)
	mux.HandleFunc("POST /production/3/device/{token}", receive)
	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12},
	}
	return server, listener, caPath, nil
}

func generateTestGatewayCertificate(ip netip.Addr) (tls.Certificate, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "Test APNs"},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:           []net.IP{ip.AsSlice()},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, ca, nil
}

func receivePush(dir string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.PathValue("token")
		if _, err := hex.DecodeString(token); err != nil || token == "" {
			http.Error(w, "BadDeviceToken", http.StatusBadRequest)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 8192))
		if err != nil || !json.Valid(body) {
			http.Error(w, "BadPayload", http.StatusBadRequest)
			return
		}
		folder := filepath.Join(dir, "pushes", strings.ToLower(token))
		if err := recordPush(folder, body); err != nil {
			fmt.Fprintln(os.Stderr, "record APNs push:", err)
			http.Error(w, "Could not record push", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
	}
}

func recordPush(folder string, body []byte) error {
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return err
	}
	// Publish a complete payload so a polling reader can open it immediately.
	tmp, err := os.CreateTemp(folder, fmt.Sprintf(".%020d-*", time.Now().UnixNano()))
	if err != nil {
		return err
	}
	_, writeErr := tmp.Write(body)
	err = errors.Join(writeErr, tmp.Close())
	if err == nil {
		name := strings.TrimPrefix(filepath.Base(tmp.Name()), ".") + ".json"
		err = os.Rename(tmp.Name(), filepath.Join(folder, name))
	}
	if err != nil {
		return errors.Join(err, os.Remove(tmp.Name()))
	}
	return nil
}
