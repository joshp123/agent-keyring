// Written by AI on 2026.11.27 by model gpt-6.2-sol.

package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReceivesPushes(t *testing.T) {
	dir := t.TempDir()
	server, listener, caPath, err := prepareServer(dir, "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	stopped := make(chan error, 1)
	go func() { stopped <- server.ServeTLS(listener, "", "") }()
	t.Cleanup(func() {
		if err := server.Close(); err != nil {
			t.Error(err)
		}
		if err := <-stopped; !errors.Is(err, http.ErrServerClosed) {
			t.Errorf("ServeTLS stopped with %v", err)
		}
	})

	if want := filepath.Join(dir, "apple-ca.pem"); caPath != want {
		t.Fatalf("CA path = %s, want %s", caPath, want)
	}
	ca, err := os.ReadFile(caPath)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		t.Fatal("apple-ca.pem contains no certificate")
	}

	for _, test := range []struct {
		proto  string
		prefix string
		token  string
		h2     bool
	}{
		{"HTTP/1.1", "", "ab12", false},
		{"HTTP/2.0", "/sandbox", "cd34", true},
		{"HTTP/2.0", "/production", "ef56", true},
	} {
		t.Run(test.proto+test.prefix, func(t *testing.T) {
			transport := &http.Transport{
				TLSClientConfig:   &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12},
				ForceAttemptHTTP2: test.h2,
			}
			t.Cleanup(transport.CloseIdleConnections)
			client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
			payload := `{ "aps": { "content-available": 1 } }`
			postPush(t, client, "https://"+listener.Addr().String()+test.prefix+"/3/device/"+test.token, payload, test.proto)
			assertPayload(t, filepath.Join(dir, "pushes", test.token), payload)
		})
	}
}

func postPush(t *testing.T, client *http.Client, url, payload, proto string) {
	t.Helper()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodPost, url, strings.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			t.Error(err)
		}
	}()
	if resp.StatusCode != http.StatusOK || resp.Proto != proto {
		t.Fatalf("POST = %s %s, want %s 200 OK", resp.Proto, resp.Status, proto)
	}
}

func assertPayload(t *testing.T, folder, payload string) {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(folder, "*.json"))
	if err != nil || len(files) != 1 {
		t.Fatalf("recorded files = %v, err = %v", files, err)
	}
	got, err := os.ReadFile(files[0])
	if err != nil || string(got) != payload {
		t.Fatalf("recorded payload = %q, err = %v, want %q", got, err, payload)
	}
}
