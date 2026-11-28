// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package browserbridge

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/authority"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/receiver"
	"google.golang.org/protobuf/encoding/protojson"
)

func readBrowserNativeResponse(input io.Reader) (*Response, error) {
	var size uint32
	if err := binary.Read(input, binary.LittleEndian, &size); err != nil {
		return nil, err
	}
	if size == 0 || size > authority.MaxFrame {
		return nil, errors.New("Invalid browser message size.")
	}
	data := make([]byte, size)
	defer clear(data)
	if _, err := io.ReadFull(input, data); err != nil {
		return nil, err
	}
	response := new(Response)
	if protojson.Unmarshal(data, response) != nil {
		return nil, errors.New("Invalid browser message.")
	}
	return response, nil
}

type browserNativeHost struct {
	ctx       context.Context
	output    io.Writer
	responses chan *Response
	choose    func(context.Context) (authority.KeyringAuthorityClient, error)
	mutex     sync.Mutex
}

func (h *browserNativeHost) sendExtensionRequest(request *ExtensionRequest) (*Response, error) {
	request.Id = receiver.GenerateOperationID()
	data, err := protojson.Marshal(request)
	if err != nil {
		return nil, err
	}
	defer clear(data)
	framed := make([]byte, 4+len(data))
	defer clear(framed)
	binary.LittleEndian.PutUint32(framed, uint32(len(data)))
	copy(framed[4:], data)
	if _, err = h.output.Write(framed); err != nil {
		return nil, errors.New("The browser connection ended.")
	}
	// Filling can wait ten seconds for readiness, then ten for consumption.
	timeout := time.NewTimer(25 * time.Second)
	defer timeout.Stop()
	for {
		select {
		case response, ok := <-h.responses:
			if !ok {
				return nil, errors.New("The browser disconnected. Inspect the tab before retrying.")
			}
			if response.Id != request.Id {
				continue
			}
			if response.Error != "" {
				return nil, errors.New(response.Error)
			}
			return response, nil
		case <-timeout.C:
			return nil, errors.New("The browser did not confirm the operation. Inspect before retrying.")
		case <-h.ctx.Done():
			return nil, errors.New("The browser connection ended.")
		}
	}
}

func RunBrowserNativeHost(ctx context.Context, origin string, choose func(context.Context) (authority.KeyringAuthorityClient, error)) error {
	if origin != "chrome-extension://"+ExtensionID+"/" {
		return errors.New("This native host accepts only the Agent Keyring browser extension.")
	}
	hello, err := readBrowserNativeResponse(os.Stdin)
	if err != nil {
		return err
	}
	if !profileID.MatchString(hello.Profile) {
		return errors.New("Invalid browser profile identity.")
	}
	directory, err := socketDirectory()
	if err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(directory, hello.Profile+".lock"), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer func() { _ = lock.Close() }()
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return errors.New("This browser profile already has a helper.")
	}
	path := filepath.Join(directory, hello.Profile+".sock")
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	listener, err := (&net.ListenConfig{}).Listen(ctx, "unix", path)
	if err != nil {
		return err
	}
	defer func() { _ = listener.Close() }()
	if err = os.Chmod(path, 0600); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	h := &browserNativeHost{ctx: ctx, output: os.Stdout, responses: make(chan *Response, 8), choose: choose}
	go h.readExtension(cancel)
	return h.acceptBrowserBridgeConnections(listener)
}

func (h *browserNativeHost) readExtension(cancel context.CancelFunc) {
	defer cancel()
	defer close(h.responses)
	for {
		response, err := readBrowserNativeResponse(os.Stdin)
		if err != nil {
			return
		}
		select {
		case h.responses <- response:
		case <-h.ctx.Done():
			return
		}
	}
}

func (h *browserNativeHost) acceptBrowserBridgeConnections(listener net.Listener) error {
	stop := context.AfterFunc(h.ctx, func() { _ = listener.Close() })
	defer stop()
	for {
		conn, e := listener.Accept()
		if e != nil {
			if h.ctx.Err() != nil {
				return nil
			}
			return e
		}
		go h.serveBrowserBridgeConnection(conn)
	}
}

func (h *browserNativeHost) serveBrowserBridgeConnection(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	if err := conn.SetDeadline(time.Now().Add(45 * time.Second)); err != nil {
		return
	}
	request := new(Request)
	if authority.ReadSocketFrame(conn, request) != nil {
		return
	}
	h.mutex.Lock()
	defer h.mutex.Unlock()
	response, err := h.dispatchBrowserBridgeRequest(request)
	if err != nil {
		response = &Response{Error: err.Error()}
	}
	// The caller gets a connection error if it disconnected before the reply.
	_ = authority.WriteSocketFrame(conn, response)
}

func (h *browserNativeHost) dispatchBrowserBridgeRequest(request *Request) (*Response, error) {
	switch request.Action {
	case Action_ACTION_TABS, Action_ACTION_FIELDS:
		return h.sendExtensionRequest(&ExtensionRequest{Action: request.Action, Target: request.Target})
	case Action_ACTION_CANDIDATES:
		return h.findBrowserLoginCandidates(request)
	case Action_ACTION_FILL:
		return h.fillBrowserCredentials(request)
	}
	return nil, errors.New("Unsupported browser command.")
}
func (h *browserNativeHost) findBrowserLoginCandidates(request *Request) (*Response, error) {
	if request.Fill == nil {
		return nil, errors.New("Supply a lease for filling.")
	}
	client, err := h.choose(h.ctx)
	if err != nil {
		return nil, err
	}
	lease, err := client.FetchAuthorityLease(h.ctx, request.Fill.LeaseId)
	if err != nil {
		return nil, err
	}
	found, err := client.CallKeyringAuthority(h.ctx, &pb.AgentRequest{Request: &pb.AgentRequest_FindLogins{FindLogins: &pb.FindLoginsRequest{Query: lease.LoginId}}})
	if err != nil {
		return nil, err
	}
	var sites []string
	for _, login := range found.GetLogins().GetLogins() {
		if login.LoginId == lease.LoginId {
			sites = login.Sites
		}
	}
	response, err := h.sendExtensionRequest(&ExtensionRequest{Action: Action_ACTION_TABS})
	if err != nil {
		return nil, err
	}
	matching := []*Tab{}
	for _, tab := range response.Tabs {
		if receiver.CheckAllowedOrigin(tab.Url, sites) {
			matching = append(matching, tab)
		}
	}
	return &Response{Tabs: matching}, nil
}

func repeatBrowserFillReceipt(record *clientstate.OperationReceipt) *Response {
	outcome := record.GetFill()
	detail := "The earlier fill ended without a confirmed submission."
	if record.Outcome == nil {
		outcome = pb.FillOutcome_FILL_OUTCOME_UNCERTAIN
		detail = "The earlier fill was interrupted and may have started."
	} else if outcome == pb.FillOutcome_FILL_OUTCOME_SUBMITTED {
		detail = "This step was already submitted."
	} else if outcome == pb.FillOutcome_FILL_OUTCOME_UNCERTAIN {
		detail = "The earlier fill finished, but the browser did not confirm submission."
	}
	return &Response{Fill: &pb.FillResult{Outcome: outcome, Detail: detail + " This step is recorded; nothing was filled or submitted again. Run tabs and inspect the page before using --again."}}
}
func (h *browserNativeHost) fillBrowserCredentials(request *Request) (*Response, error) {
	command := request.Fill
	if command == nil || command.LeaseId == "" || len(command.Fields) == 0 || command.Submit == "" {
		return nil, errors.New("Supply a lease, fields and submit control.")
	}
	parts := []string{command.LeaseId, "extension-fill", request.Target, command.Submit}
	selected := []pb.CredentialField{}
	for _, field := range command.Fields {
		parts = append(parts, field.Field.String(), field.Selector)
		selected = append(selected, field.Field)
	}
	digest := receiver.ComputeOperationDigest(parts...)
	store, err := clientstate.DefaultClientStateStore()
	if err != nil {
		return nil, err
	}
	unlock, err := receiver.AcquireOperationLock(h.ctx, "lease", command.LeaseId)
	if err != nil {
		return nil, err
	}
	defer unlock()
	record, err := store.LookupOperation(h.ctx, command.LeaseId, command.OperationId, digest)
	if err != nil {
		return nil, err
	}
	if record != nil {
		return repeatBrowserFillReceipt(record), nil
	}
	client, err := h.choose(h.ctx)
	if err != nil {
		return nil, err
	}
	lease, err := client.FetchAuthorityLease(h.ctx, command.LeaseId)
	if err != nil {
		return nil, err
	}
	payload, sites, err := h.fillValues(client, lease, command, request.Target, selected)
	if err != nil {
		return nil, err
	}
	defer clear(payload)
	record, err = store.StartOperation(h.ctx, command.LeaseId, command.OperationId, digest, lease.NotAfterUnixSeconds)
	if err != nil {
		return nil, err
	}
	if record != nil {
		return repeatBrowserFillReceipt(record), nil
	}
	response, err := h.sendExtensionRequest(&ExtensionRequest{Action: Action_ACTION_FILL, Target: request.Target, Fields: command.Fields, Submit: command.Submit, Values: payload, Sites: sites})
	if err != nil || response.GetFill() == nil {
		response = &Response{Fill: &pb.FillResult{Outcome: pb.FillOutcome_FILL_OUTCOME_UNCERTAIN, Detail: "The browser did not confirm the fill. This step is recorded; repeating it will not submit again. Run tabs and inspect the page before using --again."}}
	}
	if err = store.FinishOperation(context.WithoutCancel(h.ctx), &clientstate.OperationReceipt{LeaseId: command.LeaseId, Key: command.OperationId, Digest: digest, Outcome: &clientstate.OperationReceipt_Fill{Fill: response.Fill.Outcome}}); err != nil {
		return nil, errors.New("The fill ended but its receipt could not be saved. Inspect before retrying.")
	}
	return response, nil
}

func (h *browserNativeHost) fillValues(client authority.KeyringAuthorityClient, lease *pb.Lease, command *FillCommand, target string, selected []pb.CredentialField) ([]string, []string, error) {
	prepared, err := h.sendExtensionRequest(&ExtensionRequest{Action: Action_ACTION_PREPARE, Target: target, Fields: command.Fields, Submit: command.Submit})
	if err != nil {
		return nil, nil, err
	}
	if prepared.GetInspection().GetTab() == nil {
		return nil, nil, errors.New("The browser did not identify the target document.")
	}
	delivery, err := client.DeliverAuthorityCredential(h.ctx, &pb.DeliverRequest{LeaseId: command.LeaseId, Kind: pb.OperationKind_OPERATION_KIND_FILL, Fields: selected})
	if err != nil {
		return nil, nil, err
	}
	values, sites, err := receiver.ResolveDeliveredCredentialValues(h.ctx, client, lease, delivery, selected)
	if err != nil {
		return nil, nil, err
	}
	defer receiver.WipeDeliveredValues(values)
	if !receiver.CheckAllowedOrigin(prepared.Inspection.Tab.Url, sites) {
		return nil, nil, errors.New("This frame is outside the approved login's saved destinations. Nothing was filled.")
	}
	payload := make([]string, len(selected))
	for i, field := range selected {
		payload[i] = receiver.ExtractDeliveredValue(values, field)
	}
	return payload, sites, nil
}
