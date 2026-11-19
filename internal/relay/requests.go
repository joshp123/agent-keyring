// Written by AI on 2026.11.18 by model claude opus 5.5; the practice request's words on 2026.11.19.
package relay

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"slices"
	"strings"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

func unmarshal(raw []byte, message proto.Message) error { return proto.Unmarshal(raw, message) }

func marshal(message proto.Message) []byte {
	raw, err := proto.Marshal(message)
	if err != nil {
		panic(err) // Only messages the relay built itself are marshalled.
	}
	return raw
}

func newID() string {
	raw := make([]byte, 16)
	rand.Read(raw)
	return hex.EncodeToString(raw)
}

func heldOffKey(machineID, loginID string) string { return machineID + "/" + loginID }

func (r *request) lease(id string) *pb.Lease {
	parsed := &pb.Request{}
	unmarshal(r.Request, parsed)
	return &pb.Lease{RequestId: id, LoginId: parsed.LoginId, State: r.State, AnswerByUnixSeconds: r.AnswerBy,
		NotAfterUnixSeconds: r.NotAfter, AnsweredBy: r.AnsweredBy, Reply: r.Reply, RetryNotBeforeUnixSeconds: r.RetryNotBefore,
		EndedBy: r.EndedBy, Automatic: r.Automatic}
}

// ask records a request the asking machine wrote and signed. One the
// catalogue lets this machine take without asking is granted at once.
func (s *Server) ask(ctx context.Context, who caller, document *pb.Signed) (*pb.Lease, error) {
	members, _ := s.Store.documents()
	parsed, machine, err := keyring.CheckRequest(document.GetPayload(), document.GetSignature(), members)
	if err != nil || machine.MachineId != who.machine.MachineId || parsed.ForDeviceKeyId != "" || len(parsed.RequestId) != 32 {
		return nil, fail(pb.ErrorCode_ERROR_CODE_INVALID, "A request is written and signed by the machine that sends it.")
	}
	if len(parsed.Reason) > 400 || len(parsed.Agent) > 100 || len(parsed.Project) > 100 || len(parsed.Task) > 100 {
		return nil, fail(pb.ErrorCode_ERROR_CODE_INVALID, "The reason must be at most 400 bytes, and the agent, project and task at most 100.")
	}
	if strings.TrimSpace(parsed.Reason) == "" {
		return nil, fail(pb.ErrorCode_ERROR_CODE_INVALID, "Give a reason: it is shown to Josh when he decides.")
	}
	now := s.now()
	if skew := parsed.AskedUnixSeconds - now.Unix(); skew > 300 || skew < -300 ||
		parsed.AnswerByUnixSeconds <= parsed.AskedUnixSeconds || parsed.AnswerByUnixSeconds-parsed.AskedUnixSeconds > 600 {
		return nil, fail(pb.ErrorCode_ERROR_CODE_INVALID, "This machine's clock is more than five minutes from the relay's. Set it right and ask again.")
	}
	login := s.Store.findLogin(parsed.LoginId)
	if login == nil {
		return nil, fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "No such login. Use 'agent-keyring find' for its ID.")
	}
	if login.Rule == pb.Rule_RULE_BLOCKED {
		return nil, fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "This login is blocked for agents.")
	}
	if parsed.Automatic && (login.Rule != pb.Rule_RULE_AUTOMATIC || !machine.AutomaticAllowed) {
		return nil, fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "This login is not Automatic for this machine. Ask without --automatic.")
	}
	id := parsed.RequestId
	var result *pb.Lease
	var fresh *request
	err = s.Store.update(func(data *saved) error {
		if existing := data.Requests[id]; existing != nil {
			if existing.MachineID != machine.MachineId || !bytes.Equal(existing.Request, document.Payload) {
				return fail(pb.ErrorCode_ERROR_CODE_CONFLICT, "Another request has this ID.")
			}
			result = existing.lease(id) // The same request again: a retry.
			return nil
		}
		if until := data.HeldOff[heldOffKey(machine.MachineId, parsed.LoginId)]; until > now.Unix() && !parsed.Automatic {
			return fail(pb.ErrorCode_ERROR_CODE_HELD_OFF, "Josh denied this login for this machine. Ask again after "+time.Unix(until, 0).Format("15:04")+".")
		}
		fresh = &request{Request: document.Payload, Signature: document.Signature, MachineID: machine.MachineId,
			State: pb.LeaseState_LEASE_STATE_WAITING, AnswerBy: min(parsed.AnswerByUnixSeconds, now.Add(s.answerWithin()).Unix())}
		if parsed.Automatic {
			fresh.State, fresh.Automatic, fresh.NotAfter = pb.LeaseState_LEASE_STATE_APPROVED, true, now.Unix()+keyring.ApprovalSeconds
		}
		data.Requests[id] = fresh
		result = fresh.lease(id)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if fresh != nil {
		slog.Info("request", "id", id, "machine", machine.Label, "login", parsed.LoginId, "automatic", parsed.Automatic)
		go s.pushAll(context.WithoutCancel(ctx), id)
	}
	return result, nil
}

// owned returns a request of this machine's, or fails without saying whether
// someone else's exists.
func owned(data *saved, who caller, id string) (*request, error) {
	r := data.Requests[id]
	if r == nil || who.machine == nil || r.MachineID != who.machine.MachineId {
		return nil, fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "No such request from this machine.")
	}
	return r, nil
}

// watch streams the request's state until it is no longer waiting.
func (s *Server) watch(ctx context.Context, who caller, id string, send func(*pb.RelayResponse) error) error {
	var last *pb.Lease
	for {
		var lease *pb.Lease
		var missing error
		changed := s.Store.read(func(data *saved) {
			r, err := owned(data, who, id)
			if err != nil {
				missing = err
				return
			}
			lease = r.lease(id)
		})
		if missing != nil {
			return missing
		}
		final := lease.State != pb.LeaseState_LEASE_STATE_WAITING
		if last == nil || !proto.Equal(last, lease) {
			if err := send(&pb.RelayResponse{Result: &pb.RelayResponse_Lease{Lease: lease}, EndOfStream: final}); err != nil {
				return nil
			}
			last = lease
		}
		if final {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case <-changed:
		}
	}
}

// collect gives the asking machine what it needs to check an answer itself.
func (s *Server) collect(who caller, id string) (*pb.Approval, error) {
	var approval *pb.Approval
	var result error
	s.Store.read(func(data *saved) {
		r, err := owned(data, who, id)
		if err != nil {
			result = err
			return
		}
		if len(r.Answer) == 0 {
			result = fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "There is no signed answer to collect for this request.")
			return
		}
		upload := &pb.AnswerUpload{}
		unmarshal(r.Answer, upload)
		if r.State != pb.LeaseState_LEASE_STATE_APPROVED && r.State != pb.LeaseState_LEASE_STATE_DENIED {
			result = fail(pb.ErrorCode_ERROR_CODE_CONFLICT, "This approval has ended.")
			return
		}
		approval = &pb.Approval{Request: r.Request, Answer: upload.Answer, Delivery: upload.Delivery}
	})
	return approval, result
}

// end stops a request: the machine that asked, when it is done or stops
// asking; or a device, which can end an approval early (Stop).
func (s *Server) end(ctx context.Context, who caller, id, answeredHere string) (*pb.Lease, error) {
	var lease *pb.Lease
	var wasWaiting bool
	err := s.Store.update(func(data *saved) error {
		r, err := owned(data, who, id)
		if err != nil && who.device != nil && data.Requests[id] != nil && data.Requests[id].ForDevice == "" {
			r, err = data.Requests[id], nil
			if r.State != pb.LeaseState_LEASE_STATE_APPROVED {
				lease = r.lease(id)
				return nil
			}
		}
		if err != nil {
			return err
		}
		// Only a Mac answers its own agents' requests itself; any other computer only stops asking.
		mac := who.machine != nil && who.device != nil && who.device.Kind == pb.DeviceKind_DEVICE_KIND_MAC
		switch {
		case r.State == pb.LeaseState_LEASE_STATE_WAITING && mac && answeredHere == "approved":
			// A Mac answered its own agent's request itself: the devices show it as approved there.
			r.State, r.AnsweredBy, r.NotAfter = pb.LeaseState_LEASE_STATE_APPROVED, who.machine.Label, s.now().Unix()+keyring.ApprovalSeconds
			lease = r.lease(id)
			return nil
		case r.State == pb.LeaseState_LEASE_STATE_WAITING && mac && answeredHere == "denied":
			r.State, r.AnsweredBy = pb.LeaseState_LEASE_STATE_DENIED, who.machine.Label
			r.RetryNotBefore = s.now().Add(heldOffFor).Unix()
			parsed := &pb.Request{}
			unmarshal(r.Request, parsed)
			data.HeldOff[heldOffKey(r.MachineID, parsed.LoginId)] = r.RetryNotBefore
		case r.State == pb.LeaseState_LEASE_STATE_WAITING:
			r.State, wasWaiting = pb.LeaseState_LEASE_STATE_CANCELLED, true
		case r.State == pb.LeaseState_LEASE_STATE_APPROVED:
			r.State = pb.LeaseState_LEASE_STATE_ENDED
			if who.device != nil {
				r.EndedBy = who.device.Label
			}
		}
		r.Ended = s.now().Unix()
		lease = r.lease(id)
		return nil
	})
	if err == nil && lease != nil {
		go s.pushAll(context.WithoutCancel(ctx), id)
	}
	_ = wasWaiting
	return lease, err
}

// practiceLogin is what a device's practice request shows in place of a real
// login: it names no login in the catalogue, and nothing is sealed for it.
var practiceLogin = &pb.Login{Title: "example.com", Sites: []string{"example.com"}, Account: "you@example.com"}

// testRequest makes the practice request: no login, for the calling device
// or, from its iPhone, its Apple Watch, pushed like any other and streamed
// until it is answered. Only that device can answer it.
func (s *Server) testRequest(ctx context.Context, who caller, forDevice string, send func(*pb.RelayResponse) error) error {
	target := who.device
	if forDevice != "" && forDevice != who.device.KeyId {
		members, _ := s.Store.documents()
		target = device(members, forDevice)
		if target == nil || target.Kind != pb.DeviceKind_DEVICE_KIND_WATCH || who.device.Kind != pb.DeviceKind_DEVICE_KIND_IPHONE {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "An iPhone may ask for a practice request for its Apple Watch only.")
		}
	}
	now := s.now()
	id := newID()
	answerBy := now.Add(s.answerWithin()).Unix()
	s.Store.update(func(data *saved) error {
		data.Requests[id] = &request{ForDevice: target.KeyId, State: pb.LeaseState_LEASE_STATE_WAITING, AnswerBy: answerBy,
			Request: marshal(&pb.Request{Domain: keyring.RequestDomain, RequestId: id,
				Reason: "You asked me to download October’s invoice.", Agent: "Agent Keyring", Project: "Practice", ForDeviceKeyId: target.KeyId,
				AskedUnixSeconds: now.Unix(), AnswerByUnixSeconds: answerBy})}
		return nil
	})
	slog.Info("test request", "id", id, "device", target.Label)
	go s.pushAll(context.WithoutCancel(ctx), id)
	return s.followRequest(ctx, id, send)
}

// followRequest streams one request's lease until it is no longer waiting.
func (s *Server) followRequest(ctx context.Context, id string, send func(*pb.RelayResponse) error) error {
	var last pb.LeaseState
	for {
		var lease *pb.Lease
		changed := s.Store.read(func(data *saved) {
			if r := data.Requests[id]; r != nil {
				lease = r.lease(id)
			}
		})
		if lease == nil {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "The request is gone.")
		}
		final := lease.State != pb.LeaseState_LEASE_STATE_WAITING
		if lease.State != last {
			if err := send(&pb.RelayResponse{Result: &pb.RelayResponse_Lease{Lease: lease}, EndOfStream: final}); err != nil || final {
				return nil
			}
			last = lease.State
		}
		select {
		case <-ctx.Done():
			return nil
		case <-changed:
		}
	}
}

// reportSelfTest keeps a device's latest self-test, signed by its reply key.
func (s *Server) reportSelfTest(who caller, document *pb.Signed) error {
	members, _ := s.Store.documents()
	signer, err := keyring.Verify(document, members, true)
	report := &pb.SelfTestReport{}
	if err != nil || unmarshal(document.Payload, report) != nil || report.Domain != keyring.SelfTestDomain || report.DeviceKeyId != signer.KeyId {
		return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A self-test report is signed by the device it describes.")
	}
	var failed []string
	for _, check := range report.Checks {
		if !check.Passed {
			failed = append(failed, check.Name+": "+check.Error)
		}
	}
	slog.Info("self-test", "device", signer.Label, "checks", len(report.Checks), "failed", strings.Join(failed, "; "))
	return s.Store.update(func(data *saved) error {
		if data.SelfTests == nil {
			data.SelfTests = map[string][]byte{}
		}
		data.SelfTests[signer.KeyId] = marshal(document)
		return nil
	})
}

func (s *Server) selfTests() *pb.SelfTests {
	result := &pb.SelfTests{}
	s.Store.read(func(data *saved) {
		for _, raw := range data.SelfTests {
			document := &pb.Signed{}
			if unmarshal(raw, document) == nil {
				result.Reports = append(result.Reports, document)
			}
		}
	})
	return result
}

// answer records the first answer to a request and refuses the rest.
func (s *Server) answer(ctx context.Context, who caller, upload *pb.AnswerUpload) (*pb.Lease, error) {
	members, catalogue := s.Store.documents()
	now := s.now()
	var lease *pb.Lease
	var id string
	err := s.Store.update(func(data *saved) error {
		var r *request
		var answeredBy, reply string
		var choice pb.Choice
		var notAfter int64
		if upload.DenyRequestId != "" {
			id, r = upload.DenyRequestId, data.Requests[upload.DenyRequestId]
			if r == nil {
				return fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "No such request.")
			}
			choice, answeredBy = pb.Choice_CHOICE_DENY, who.device.Label
		} else {
			if upload.Answer == nil {
				return fail(pb.ErrorCode_ERROR_CODE_INVALID, "An answer is either signed or a plain denial.")
			}
			answer := &pb.Answer{}
			if err := unmarshal(upload.Answer.Payload, answer); err != nil || answer.Domain != keyring.AnswerDomain {
				return fail(pb.ErrorCode_ERROR_CODE_INVALID, "Not an answer.")
			}
			id, r = requestBySHA(data, answer.RequestSha256)
			if r == nil {
				return fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "No request has these exact bytes.")
			}
			signer, err := keyring.Verify(upload.Answer, members, answer.Choice == pb.Choice_CHOICE_DENY)
			if err != nil {
				return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "The answer's signature does not belong to a device: "+err.Error())
			}
			if len(r.Answer) > 0 && bytes.Equal(r.Answer, marshal(upload)) {
				lease = r.lease(id) // The same answer again: already recorded.
				return nil
			}
			choice, answeredBy, reply = answer.Choice, signer.Label, answer.Reply
			if r.ForDevice != "" {
				if r.ForDevice != signer.KeyId {
					return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "Only the device the practice request is for may answer it.")
				}
			} else if choice == pb.Choice_CHOICE_APPROVE {
				parsed := &pb.Request{}
				unmarshal(r.Request, parsed)
				login := loginIn(catalogue, parsed.LoginId)
				switch {
				case upload.Delivery == nil || !bytes.Equal(answer.DeliverySha256, keyring.SHA256(upload.Delivery.Ciphertext)):
					return fail(pb.ErrorCode_ERROR_CODE_INVALID, "The approval does not match its delivery.")
				case answer.NotAfterUnixSeconds > answer.DecidedUnixSeconds+keyring.ApprovalSeconds || answer.NotAfterUnixSeconds <= now.Unix():
					return fail(pb.ErrorCode_ERROR_CODE_INVALID, "An approval lasts at most 30 minutes from when it was given.")
				case login == nil || login.Rule == pb.Rule_RULE_BLOCKED:
					return fail(pb.ErrorCode_ERROR_CODE_NOT_ALLOWED, "This login is blocked for agents.")
				}
				notAfter = answer.NotAfterUnixSeconds
			} else if choice != pb.Choice_CHOICE_DENY {
				return fail(pb.ErrorCode_ERROR_CODE_INVALID, "An answer approves or denies.")
			}
		}
		if upload.DenyRequestId != "" && r.ForDevice != "" && r.ForDevice != who.device.KeyId {
			return fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "No such request.")
		}
		if r.State != pb.LeaseState_LEASE_STATE_WAITING {
			lease = r.lease(id)
			return fail(pb.ErrorCode_ERROR_CODE_CONFLICT, "This request has already ended: "+strings.ToLower(strings.TrimPrefix(r.State.String(), "LEASE_STATE_"))+".")
		}
		r.AnsweredBy, r.Reply = answeredBy, reply
		if upload.Answer != nil {
			r.Answer = marshal(upload)
		}
		if choice == pb.Choice_CHOICE_APPROVE && r.ForDevice != "" {
			r.State, r.Ended = pb.LeaseState_LEASE_STATE_APPROVED, now.Unix()
		} else if choice == pb.Choice_CHOICE_APPROVE {
			r.State, r.NotAfter = pb.LeaseState_LEASE_STATE_APPROVED, notAfter
		} else if r.ForDevice != "" {
			r.State, r.Ended = pb.LeaseState_LEASE_STATE_DENIED, now.Unix()
		} else {
			parsed := &pb.Request{}
			unmarshal(r.Request, parsed)
			r.State, r.Ended = pb.LeaseState_LEASE_STATE_DENIED, now.Unix()
			r.RetryNotBefore = now.Add(heldOffFor).Unix()
			data.HeldOff[heldOffKey(r.MachineID, parsed.LoginId)] = r.RetryNotBefore
		}
		lease = r.lease(id)
		return nil
	})
	if err != nil {
		return lease, err
	}
	slog.Info("answer", "id", id, "state", lease.State.String(), "by", lease.AnsweredBy)
	go s.pushAll(context.WithoutCancel(ctx), id)
	return lease, nil
}

// keepDeadlines turns silence into "no answer" and ends approvals after 30 minutes.
func (s *Server) keepDeadlines(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		now := s.now().Unix()
		var due []string
		var unanswered []string
		s.Store.read(func(data *saved) {
			for id, r := range data.Requests {
				if (r.State == pb.LeaseState_LEASE_STATE_WAITING && now >= r.AnswerBy) || (r.State == pb.LeaseState_LEASE_STATE_APPROVED && now >= r.NotAfter) {
					due = append(due, id)
				}
			}
			for key, until := range data.HeldOff {
				if until <= now {
					due = append(due, "held:"+key)
				}
			}
			for _, j := range data.Joins {
				if now-j.Asked > 86400 {
					due = append(due, "joins")
				}
			}
		})
		if len(due) == 0 {
			continue
		}
		s.Store.update(func(data *saved) error {
			for _, id := range due {
				if key, held := strings.CutPrefix(id, "held:"); held {
					delete(data.HeldOff, key)
					continue
				}
				r := data.Requests[id]
				if r == nil {
					continue
				}
				switch {
				case r.State == pb.LeaseState_LEASE_STATE_WAITING && now >= r.AnswerBy:
					r.State, r.Ended = pb.LeaseState_LEASE_STATE_UNANSWERED, now
					unanswered = append(unanswered, id)
				case r.State == pb.LeaseState_LEASE_STATE_APPROVED && now >= r.NotAfter:
					r.State, r.Ended = pb.LeaseState_LEASE_STATE_ENDED, now
				}
			}
			// Keep a day of finished requests for the devices' history, and of joins.
			for id, r := range data.Requests {
				if r.Ended > 0 && now-r.Ended > 86400 {
					delete(data.Requests, id)
				}
			}
			for id, j := range data.Joins {
				if now-j.Asked > 86400 {
					delete(data.Joins, id)
				}
			}
			return nil
		})
		for _, id := range unanswered {
			go s.pushAll(ctx, id)
		}
	}
}

func (s *Server) find(query string) *pb.FindResult {
	_, catalogue := s.Store.documents()
	result := &pb.FindResult{}
	if catalogue == nil {
		return result
	}
	words := strings.Fields(strings.ToLower(query))
	for _, login := range catalogue.Logins {
		text := strings.ToLower(login.Title + " " + login.Account + " " + strings.Join(login.Sites, " ") + " " + login.LoginId)
		if !slices.ContainsFunc(words, func(word string) bool { return !strings.Contains(text, word) }) {
			result.Logins = append(result.Logins, login)
		}
	}
	return result
}

func (s *Server) sealedFor(openerID string) *pb.SealedLogins {
	result := &pb.SealedLogins{}
	s.Store.read(func(data *saved) {
		for _, raw := range data.Sealed[openerID] {
			sealed := &pb.SealedLogin{}
			if unmarshal(raw, sealed) == nil {
				result.Logins = append(result.Logins, sealed)
			}
		}
	})
	return result
}

// work is one request as one device sees it.
func (s *Server) work(device *pb.Device, id string, data *saved) (*pb.Work, error) {
	build := func(data *saved) (*pb.Work, error) {
		r := data.Requests[id]
		if r == nil {
			return nil, fail(pb.ErrorCode_ERROR_CODE_NOT_FOUND, "No such request.")
		}
		work := &pb.Work{Request: r.Request, RequestSignature: r.Signature}
		parsed := &pb.Request{}
		unmarshal(r.Request, parsed)
		if parsed.ForDeviceKeyId != "" {
			work.Login = practiceLogin
		} else if parsed.LoginId != "" {
			_, catalogue := s.Store.documentsLocked()
			work.Login = loginIn(catalogue, parsed.LoginId)
		}
		if raw := data.Sealed[device.KeyId][parsed.LoginId]; raw != nil {
			work.SealedLogin = &pb.SealedLogin{}
			unmarshal(raw, work.SealedLogin)
		}
		if r.State != pb.LeaseState_LEASE_STATE_WAITING {
			work.Outcome = r.lease(id)
		}
		return work, nil
	}
	if data != nil {
		return build(data)
	}
	var work *pb.Work
	var err error
	s.Store.read(func(data *saved) { work, err = build(data) })
	return work, err
}

// watchWork streams each waiting request, then each new one and each outcome.
func (s *Server) watchWork(ctx context.Context, who caller, send func(*pb.RelayResponse) error) error {
	sent := map[string]pb.LeaseState{}
	for {
		var batch []*pb.Work
		changed := s.Store.read(func(data *saved) {
			for id, r := range data.Requests {
				if r.ForDevice != "" && r.ForDevice != who.device.KeyId {
					continue
				}
				// New: waiting, or in use (an Automatic use starts approved).
				previous, known := sent[id]
				fresh := r.State == pb.LeaseState_LEASE_STATE_WAITING || r.State == pb.LeaseState_LEASE_STATE_APPROVED
				if (!known && fresh) || (known && previous != r.State) {
					if work, err := s.work(who.device, id, data); err == nil {
						batch = append(batch, work)
						sent[id] = r.State
					}
				}
			}
		})
		for _, work := range batch {
			if err := send(&pb.RelayResponse{Result: &pb.RelayResponse_Work{Work: work}}); err != nil {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return nil
		case <-changed:
		}
	}
}
