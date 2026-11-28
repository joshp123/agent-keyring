// Written by AI on 2026.11.27 by model gpt-6.2-sol.
package browserbridge

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/authority"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"google.golang.org/protobuf/encoding/protojson"
)

type browserOutput func([]byte) (int, error)

func (write browserOutput) Write(frame []byte) (int, error) { return write(frame) }

func TestFillCanRetryAfterRejectedOrigin(t *testing.T) {
	store := clientstate.ClientStateStore{Directory: filepath.Join(t.TempDir(), "state")}
	t.Setenv("AGENT_KEYRING_STATE_DIR", store.Directory)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	lease := &pb.Lease{
		RequestId:           "test-lease",
		NotAfterUnixSeconds: time.Now().Add(time.Minute).Unix(),
		AuthorityContext:    &pb.LeaseAuthorityContext{Sites: []string{"https://login.example"}},
	}
	client := authority.KeyringAuthorityClient{Exchange: func(_ context.Context, request *pb.AgentRequest, receive func(*pb.AgentResponse) bool) error {
		switch request.Request.(type) {
		case *pb.AgentRequest_GetLease:
			receive(&pb.AgentResponse{Response: &pb.AgentResponse_Lease{Lease: lease}})
		case *pb.AgentRequest_Deliver:
			delivery := &pb.LocalCredentialDelivery{Result: &pb.LocalCredentialDelivery_Values{Values: &pb.CredentialValues{Password: "test-password"}}}
			receive(&pb.AgentResponse{Response: &pb.AgentResponse_Delivery{Delivery: delivery}})
		default:
			return fmt.Errorf("unexpected authority request %T", request.Request)
		}
		return nil
	}}
	responses := make(chan *Response, 1)
	tabURL := "https://unrelated.example"
	fillCalls := 0
	h := &browserNativeHost{
		ctx:       ctx,
		responses: responses,
		choose:    func(context.Context) (authority.KeyringAuthorityClient, error) { return client, nil },
		output: browserOutput(func(frame []byte) (int, error) {
			request := new(ExtensionRequest)
			if err := protojson.Unmarshal(frame[4:], request); err != nil {
				t.Fatal(err)
			}
			response := &Response{Id: request.Id}
			switch request.Action {
			case Action_ACTION_PREPARE:
				response.Inspection = &Inspection{Tab: &Tab{Url: tabURL}}
			case Action_ACTION_FILL:
				fillCalls++
				response.Fill = &pb.FillResult{Outcome: pb.FillOutcome_FILL_OUTCOME_SUBMITTED}
			default:
				t.Fatalf("unexpected browser action %v", request.Action)
			}
			responses <- response
			return len(frame), nil
		}),
	}
	request := &Request{Action: Action_ACTION_FILL, Target: "test-tab", Fill: &FillCommand{
		LeaseId: lease.RequestId,
		Fields:  []*pb.FieldBinding{{Field: pb.CredentialField_CREDENTIAL_FIELD_PASSWORD, Selector: "#password"}},
		Submit:  "#submit",
	}}

	if _, err := h.dispatchBrowserBridgeRequest(request); err == nil || !strings.Contains(err.Error(), "outside the approved login's saved destinations") {
		t.Fatalf("fill on unrelated origin returned %v", err)
	}
	state, err := store.LoadClientState(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if fillCalls != 0 || len(state.GetOperations()) != 0 {
		t.Fatalf("rejected fill sent %d fill requests and recorded %d receipts", fillCalls, len(state.GetOperations()))
	}

	tabURL = lease.AuthorityContext.Sites[0]
	result, err := h.dispatchBrowserBridgeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	if fillCalls != 1 || result.GetFill().GetOutcome() != pb.FillOutcome_FILL_OUTCOME_SUBMITTED {
		t.Fatalf("retry sent %d fill requests and returned %v", fillCalls, result.GetFill())
	}
}
