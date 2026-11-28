// Written by AI on 2026.11.23 by model gemini-4-neon; /v1/push by claude opus 5.5 on 2026.11.24.
package apns

import (
	"context"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRelayModeSendsExactHeadersWithoutAuthorization(t *testing.T) {
	var gotPath, gotToken, gotEnv, gotTopic, gotType, gotPriority, gotAuth string
	var gotBody []byte

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotToken = r.URL.Path, r.Header.Get("x-akr-token")
		gotEnv = r.Header.Get("x-apns-env")
		gotTopic = r.Header.Get("apns-topic")
		gotType = r.Header.Get("apns-push-type")
		gotPriority = r.Header.Get("apns-priority")
		gotAuth = r.Header.Get("authorization")
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	sender, err := NewRelayPushSender(server.URL, PushSenderConfig{})
	if err != nil {
		t.Fatalf("NewRelay: %v", err)
	}
	token, _ := hex.DecodeString("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	payload := []byte(`{"aps":{"content-available":1},"akr":"opaque-ciphertext"}`)
	res, err := sender.SendPushNotification(context.Background(), token, "com.joshpalmer.AgentKeyring.Phone", true, "req-1", 1900000000, payload, false)
	if err != nil {
		t.Fatalf("Send: %v", err)
	}
	if res.Status != 200 {
		t.Fatalf("status = %d, want 200", res.Status)
	}
	// The address in a header, never the URL, so nothing that logs URLs sees it.
	if gotPath != "/v1/push" || gotToken != "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" {
		t.Fatalf("path = %q, x-akr-token = %q", gotPath, gotToken)
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

	sender, err := NewRelayPushSender(server.URL, PushSenderConfig{})
	if err != nil {
		t.Fatalf("NewRelay: %v", err)
	}
	token, _ := hex.DecodeString("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	res, err := sender.SendPushNotification(context.Background(), token, "com.joshpalmer.AgentKeyring.Phone", false, "req-2", 1900000000, []byte(`{"aps":{}}`), true)
	if err == nil {
		t.Fatal("expected error on 400")
	}
	if res.Status != 400 || res.Reason != "BadDeviceToken" || !res.InvalidToken {
		t.Fatalf("unexpected result: %+v", res)
	}
}

func TestRelayModeWrapsTransportError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	serverURL := server.URL
	server.Close()

	sender, err := NewRelayPushSender(serverURL, PushSenderConfig{})
	if err != nil {
		t.Fatalf("NewRelay: %v", err)
	}
	token, _ := hex.DecodeString("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	res, err := sender.SendPushNotification(context.Background(), token, "com.joshpalmer.AgentKeyring.Phone", false, "req-3", 1900000000, []byte(`{"aps":{}}`), false)
	if err == nil {
		t.Fatal("expected transport error")
	}
	if res.Status != 0 {
		t.Fatalf("status = %d, want 0", res.Status)
	}
	if !strings.Contains(err.Error(), "APNs transport failed:") || errors.Unwrap(err) == nil {
		t.Fatalf("expected wrapped transport error, got %v", err)
	}
}
