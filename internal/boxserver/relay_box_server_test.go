// Written by AI on 2026.11.24 by model claude opus 5.5.
//
// A Stop on a grant holds: no replace can clear it, and only a grant stops.
package boxserver

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAStoppedGrantStaysStopped(t *testing.T) {
	relay := httptest.NewServer(NewRelayBoxHandler(t.Context(), 1))
	defer relay.Close()

	grant := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if status, stopped := putTestRelayBox(t, relay.URL, grant, "grant", "create", "approval"); status != http.StatusCreated || stopped != "false" {
		t.Fatalf("create grant: %d stopped=%q", status, stopped)
	}
	if status, _ := putTestRelayBox(t, relay.URL, grant, "update", "replace", "approval again"); status != http.StatusForbidden {
		t.Fatalf("replace on a live grant: %d, want 403", status)
	}
	if status, stopped := putTestRelayBox(t, relay.URL, grant, "grant", "stop", "stop"); status != http.StatusOK || stopped != "true" {
		t.Fatalf("stop grant: %d stopped=%q", status, stopped)
	}
	for _, ttl := range []string{"update", "enrol"} {
		if status, _ := putTestRelayBox(t, relay.URL, grant, ttl, "replace", "approval again"); status != http.StatusForbidden {
			t.Fatalf("replace (%s) on a stopped grant: %d, want 403", ttl, status)
		}
	}
	if status, _ := putTestRelayBox(t, relay.URL, grant, "grant", "replace", "approval again"); status != http.StatusBadRequest {
		t.Fatalf("replace with a grant lifetime: %d, want 400", status)
	}
	if body, stopped := readTestRelayBox(t, relay.URL, grant); body != "stop" || stopped != "true" {
		t.Fatalf("after replaces the grant reads %q stopped=%q", body, stopped)
	}

	mailbox := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if status, _ := putTestRelayBox(t, relay.URL, mailbox, "update", "create", "update 1"); status != http.StatusCreated {
		t.Fatalf("create mailbox: %d", status)
	}
	if status, _ := putTestRelayBox(t, relay.URL, mailbox, "grant", "stop", "stop"); status != http.StatusForbidden {
		t.Fatalf("stop on an update mailbox: %d, want 403", status)
	}
	if status, _ := putTestRelayBox(t, relay.URL, mailbox, "update", "replace", "update 2"); status != http.StatusCreated {
		t.Fatalf("replace on a mailbox: %d", status)
	}
	if body, stopped := readTestRelayBox(t, relay.URL, mailbox); body != "update 2" || stopped != "" {
		t.Fatalf("mailbox reads %q stopped=%q", body, stopped)
	}
}

func putTestRelayBox(t *testing.T, relayURL, id, ttl, mode, body string) (int, string) {
	const write = "write-token-write-token-write-token-0"
	t.Helper()
	request, err := http.NewRequestWithContext(t.Context(), http.MethodPut, relayURL+"/v1/box", bytes.NewBufferString(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/octet-stream")
	request.Header.Set("x-akr-box", id)
	request.Header.Set("x-akr-ttl", ttl)
	request.Header.Set("x-akr-mode", mode)
	request.Header.Set("x-akr-write-auth", write)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if err := response.Body.Close(); err != nil {
		t.Fatal(err)
	}
	return response.StatusCode, response.Header.Get("x-akr-stopped")
}
func readTestRelayBox(t *testing.T, relayURL, id string) (string, string) {
	t.Helper()
	request, err := http.NewRequestWithContext(t.Context(), http.MethodGet, relayURL+"/v1/box", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("x-akr-box", id)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := response.Body.Close(); err != nil {
			t.Error(err)
		}
	}()
	var body bytes.Buffer
	if _, err := body.ReadFrom(response.Body); err != nil {
		t.Fatal(err)
	}
	return body.String(), response.Header.Get("x-akr-stopped")
}
