// Written by AI on 2026.11.27 by model gemini-4-hydrogen.
package receiver

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/authority"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
)

func TestReadLeavesNoOrphanedOperationReceipts(t *testing.T) {
	store := clientstate.ClientStateStore{Directory: filepath.Join(t.TempDir(), "state")}
	lease := &pb.Lease{
		RequestId:           "lease-read-1",
		NotAfterUnixSeconds: time.Now().Add(10 * time.Minute).Unix(),
	}

	// 1. Deliver fails: no receipt may remain in state.Operations.
	failingDeliver := authority.KeyringAuthorityClient{
		State: store,
		Exchange: func(context.Context, *pb.AgentRequest, func(*pb.AgentResponse) bool) error {
			return errors.New("deliver failed")
		},
	}
	var out bytes.Buffer
	if err := ReadDeliveredCredential(context.Background(), failingDeliver, lease, pb.CredentialField_CREDENTIAL_FIELD_PASSWORD, &out); err == nil {
		t.Fatal("expected Read to fail when Deliver fails")
	}
	st, err := store.LoadClientState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Operations) != 0 {
		t.Fatalf("expected 0 operation receipts after Deliver failure, got %d", len(st.Operations))
	}

	// 2. ResolveDeliveredCredentialValues fails (empty response): no receipt may remain in state.Operations.
	failingDelivered := authority.KeyringAuthorityClient{
		State: store,
		Exchange: func(_ context.Context, _ *pb.AgentRequest, receive func(*pb.AgentResponse) bool) error {
			receive(&pb.AgentResponse{
				Response:    &pb.AgentResponse_Delivery{Delivery: &pb.LocalCredentialDelivery{}},
				EndOfStream: true,
			})
			return nil
		},
	}
	if err := ReadDeliveredCredential(context.Background(), failingDelivered, lease, pb.CredentialField_CREDENTIAL_FIELD_PASSWORD, &out); err == nil {
		t.Fatal("expected Read to fail when Delivered finds no values")
	}
	st, err = store.LoadClientState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Operations) != 0 {
		t.Fatalf("expected 0 operation receipts after Delivered failure, got %d", len(st.Operations))
	}

	// 3. Successful ReadDeliveredCredential writes the value cleanly without adding operation receipts.
	succeeding := authority.KeyringAuthorityClient{
		State: store,
		Exchange: func(_ context.Context, _ *pb.AgentRequest, receive func(*pb.AgentResponse) bool) error {
			receive(&pb.AgentResponse{
				Response: &pb.AgentResponse_Delivery{Delivery: &pb.LocalCredentialDelivery{
					Result: &pb.LocalCredentialDelivery_Values{Values: &pb.CredentialValues{Password: "secret-pass"}},
				}},
				EndOfStream: true,
			})
			return nil
		},
	}
	if err := ReadDeliveredCredential(context.Background(), succeeding, lease, pb.CredentialField_CREDENTIAL_FIELD_PASSWORD, &out); err != nil {
		t.Fatalf("Read: %v", err)
	}
	if out.String() != "secret-pass" {
		t.Fatalf("output = %q, want secret-pass", out.String())
	}
	st, err = store.LoadClientState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Operations) != 0 {
		t.Fatalf("expected 0 operation receipts for non-idempotent Read, got %d", len(st.Operations))
	}
}
