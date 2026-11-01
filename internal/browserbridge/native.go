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

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/receiver"
	"google.golang.org/protobuf/encoding/protojson"
)

func readNative(input io.Reader) (*Response, error) {
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

type host struct {
	ctx       context.Context
	responses chan *Response
	choose    func(context.Context) (authority.Client, error)
	mutex     sync.Mutex
}

func (h *host) browser(request *ExtensionRequest) (*Response, error) {
	request.Id = receiver.NewID()
	data, err := protojson.Marshal(request)
	if err != nil {
		return nil, err
	}
	defer clear(data)
	framed := make([]byte, 4+len(data))
	defer clear(framed)
	binary.LittleEndian.PutUint32(framed, uint32(len(data)))
	copy(framed[4:], data)
	if _, err = os.Stdout.Write(framed); err != nil {
		return nil, errors.New("The browser connection ended.")
	}
	timeout := time.NewTimer(15 * time.Second)
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

func Native(ctx context.Context, origin string, choose func(context.Context) (authority.Client, error)) error {
	if origin != "chrome-extension://"+ExtensionID+"/" {
		return errors.New("This native host accepts only the Agent Keyring browser extension.")
	}
	hello, err := readNative(os.Stdin)
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
	defer lock.Close()
	if syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return errors.New("This browser profile already has a helper.")
	}
	path := filepath.Join(directory, hello.Profile+".sock")
	os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(path)
	if err = os.Chmod(path, 0600); err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	h := &host{ctx: ctx, responses: make(chan *Response, 8), choose: choose}
	go func() {
		defer cancel()
		defer close(h.responses)
		for {
			response, e := readNative(os.Stdin)
			if e != nil {
				return
			}
			select {
			case h.responses <- response:
			case <-ctx.Done():
				return
			}
		}
	}()
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()
	for {
		conn, e := listener.Accept()
		if e != nil {
			if ctx.Err() != nil {
				return nil
			}
			return e
		}
		go func() {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(45 * time.Second))
			request := new(Request)
			if authority.ReadFrame(conn, request) != nil {
				return
			}
			h.mutex.Lock()
			defer h.mutex.Unlock()
			response, e := h.handle(request)
			if e != nil {
				response = &Response{Error: e.Error()}
			}
			authority.WriteFrame(conn, response)
		}()
	}
}
func (h *host) handle(request *Request) (*Response, error) {
	switch request.Action {
	case Action_ACTION_TABS, Action_ACTION_FIELDS:
		return h.browser(&ExtensionRequest{Action: request.Action, Target: request.Target})
	case Action_ACTION_CANDIDATES:
		if request.Fill == nil {
			return nil, errors.New("Supply a lease for filling.")
		}
		client, err := h.choose(h.ctx)
		if err != nil {
			return nil, err
		}
		lease, err := client.Lease(h.ctx, request.Fill.LeaseId)
		if err != nil {
			return nil, err
		}
		found, err := client.Call(h.ctx, &pb.WireRequest{Request: &pb.WireRequest_FindLogins{FindLogins: &pb.FindLoginsRequest{Query: lease.LoginId}}})
		if err != nil {
			return nil, err
		}
		var sites []string
		for _, login := range found.GetLogins().GetLogins() {
			if login.LoginId == lease.LoginId {
				sites = login.Sites
			}
		}
		response, err := h.browser(&ExtensionRequest{Action: Action_ACTION_TABS})
		if err != nil {
			return nil, err
		}
		matching := []*Tab{}
		for _, tab := range response.Tabs {
			if receiver.AllowedOrigin(tab.Url, sites) {
				matching = append(matching, tab)
			}
		}
		return &Response{Tabs: matching}, nil
	case Action_ACTION_FILL:
		return h.fill(request)
	}
	return nil, errors.New("Unsupported browser command.")
}
func previous(record *clientstate.OperationReceipt) *Response {
	if record.GetFill() == pb.FillOutcome_FILL_OUTCOME_SUBMITTED {
		return &Response{Fill: &pb.FillResult{Outcome: 1, Detail: "This step was already submitted. Nothing was filled again; run tabs to inspect the current page."}}
	}
	return &Response{Fill: &pb.FillResult{Outcome: 2, Detail: "The earlier fill may have started. This step is recorded; nothing was filled or submitted again. Inspect the page before using --again."}}
}
func (h *host) fill(request *Request) (*Response, error) {
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
	digest := receiver.Digest(parts...)
	store, err := clientstate.Default()
	if err != nil {
		return nil, err
	}
	unlock, err := receiver.LockOperation(h.ctx, "lease", command.LeaseId)
	if err != nil {
		return nil, err
	}
	defer unlock()
	record, err := store.LookupOperation(h.ctx, command.LeaseId, command.OperationId, digest)
	if err != nil {
		return nil, err
	}
	if record != nil {
		return previous(record), nil
	}
	client, err := h.choose(h.ctx)
	if err != nil {
		return nil, err
	}
	lease, err := client.Lease(h.ctx, command.LeaseId)
	if err != nil {
		return nil, err
	}
	if lease.Purpose != pb.Purpose_PURPOSE_BROWSER_SIGN_IN {
		return nil, errors.New("This lease does not approve browser sign-in.")
	}
	prepared, err := h.browser(&ExtensionRequest{Action: Action_ACTION_PREPARE, Target: request.Target, Fields: command.Fields, Submit: command.Submit})
	if err != nil {
		return nil, err
	}
	if prepared.GetInspection().GetTab() == nil {
		return nil, errors.New("The browser did not identify the target document.")
	}
	record, err = store.StartOperation(h.ctx, command.LeaseId, command.OperationId, digest, lease.NotAfterUnixSeconds)
	if err != nil {
		return nil, err
	}
	if record != nil {
		return previous(record), nil
	}
	delivery, err := client.Deliver(h.ctx, &pb.DeliverRequest{LeaseId: command.LeaseId, Kind: pb.OperationKind_OPERATION_KIND_FILL, Fields: selected})
	if err != nil {
		return nil, err
	}
	values, sites, err := receiver.Delivered(h.ctx, client, lease, delivery, selected)
	if err != nil {
		return nil, err
	}
	defer receiver.ClearValues(values)
	if !receiver.AllowedOrigin(prepared.Inspection.Tab.Url, sites) {
		return nil, errors.New("This frame is outside the approved login's saved destinations. Nothing was filled.")
	}
	payload := make([]string, len(selected))
	defer clear(payload)
	for i, field := range selected {
		payload[i] = receiver.Value(values, field)
	}
	response, err := h.browser(&ExtensionRequest{Action: Action_ACTION_FILL, Target: request.Target, Fields: command.Fields, Submit: command.Submit, Values: payload, Sites: sites})
	if err != nil || response.GetFill() == nil {
		response = &Response{Fill: &pb.FillResult{Outcome: 2, Detail: "The browser did not confirm the fill. This step is recorded; repeating it will not submit again. Run tabs and inspect the page before using --again."}}
	}
	if err = store.FinishOperation(context.WithoutCancel(h.ctx), &clientstate.OperationReceipt{LeaseId: command.LeaseId, Key: command.OperationId, Digest: digest, Outcome: &clientstate.OperationReceipt_Fill{Fill: response.Fill.Outcome}}); err != nil {
		return nil, errors.New("The fill ended but its receipt could not be saved. Inspect before retrying.")
	}
	return response, nil
}
