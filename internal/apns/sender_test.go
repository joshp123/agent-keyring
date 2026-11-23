// Written by AI on 2026.11.23 by model gemini-4-neon.
package apns

import (
	"context"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestRelayModeSendsExactHeadersWithoutAuthorization(t *testing.T) {
	var gotPath, gotEnv, gotTopic, gotType, gotPriority, gotAuth string
	var gotBody []byte

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotEnv = r.Header.Get("x-apns-env")
		gotTopic = r.Header.Get("apns-topic")
		gotType = r.Header.Get("apns-push-type")
		gotPriority = r.Header.Get("apns-priority")
		gotAuth = r.Header.Get("authorization")
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	sender, err := NewRelay(server.URL, Config{})
	if err != nil {
		t.Fatalf("NewRelay: %v", err)
	}
	token, _ := hex.DecodeString("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	payload := []byte(`{"aps":{"content-available":1},"akr":"opaque-ciphertext"}`)
	res, err := sender.Send(context.Background(), token, "com.joshpalmer.AgentKeyring.Phone", true, "req-1", 1900000000, payload, false)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if res.Status != 200 {
		t.Fatalf("status = %d, want 200", res.Status)
	}
	if gotPath != "/3/device/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" {
		t.Fatalf("path = %q", gotPath)
	}
	if gotEnv != "production" {
		t.Fatalf("x-apns-env = %q, want production", gotEnv)
	}
	if gotTopic != "com.joshpalmer.AgentKeyring.Phone" || gotType != "background" || gotPriority != "5" {
		t.Fatalf("headers topic=%q type=%q priority=%q", gotTopic, gotType, gotPriority)
	}
	if gotAuth != "" {
		t.Fatalf("relay mode must not send authorization header, got %q", gotAuth)
	}
	if string(gotBody) != string(payload) {
		t.Fatalf("body = %q, want %q", gotBody, payload)
	}
}

func TestRelayModePropagatesAppleInvalidToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("x-apns-env") != "sandbox" {
			t.Errorf("x-apns-env = %q, want sandbox", r.Header.Get("x-apns-env"))
		}
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"reason":"BadDeviceToken"}`))
	}))
	defer server.Close()

	sender, err := NewRelay(server.URL, Config{})
	if err != nil {
		t.Fatalf("NewRelay: %v", err)
	}
	token, _ := hex.DecodeString("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	res, err := sender.Send(context.Background(), token, "com.joshpalmer.AgentKeyring.Phone", false, "req-2", 1900000000, []byte(`{"aps":{}}`), true)
	if err == nil {
		t.Fatal("expected error on 400")
	}
	if res.Status != 400 || res.Reason != "BadDeviceToken" || !res.InvalidToken {
		t.Fatalf("unexpected result: %+v", res)
	}
}
