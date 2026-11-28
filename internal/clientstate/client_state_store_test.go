// Written by AI on 2026.11.27 by model gpt-6.2-sol.
package clientstate

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/proto"
)

func newTestClientStateStore(t *testing.T) ClientStateStore {
	t.Helper()
	directory := filepath.Join(t.TempDir(), "state")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	return ClientStateStore{Directory: directory}
}

func TestWriteRejectsOversizedStateWithoutReplacingSavedState(t *testing.T) {
	ctx := context.Background()
	store := newTestClientStateStore(t)
	previous := &State{RecipientId: "enrolled-computer"}
	if err := store.writeClientStateMessage("state.pb", previous); err != nil {
		t.Fatal(err)
	}

	oversized := &State{Bundle: make([]byte, MaxStateBytes)}
	if err := store.writeClientStateMessage("state.pb", oversized); err == nil || !strings.Contains(err.Error(), "write limit") {
		t.Fatalf("oversized write returned %v", err)
	}
	saved, err := store.LoadClientState(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(saved, previous) {
		t.Fatal("oversized write replaced the saved state")
	}
}
