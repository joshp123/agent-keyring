// Written by AI on 2026.11.21 by model claude opus 5.5.
package remote

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

// doorHandler is this computer's door, for its own requests
// (proto/agentkeyring/v2/keyring.proto, "The answer door"). Each answer is
// trusted by its signature, checked against the newest Members this computer
// holds, and taken under the state file's lock, so the first answer wins
// whichever of this computer's processes holds the door.
func (c *Client) doorHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v2/answer", c.takeAnswer)
	mux.HandleFunc("POST /v2/arrived", c.takeArrival)
	mux.HandleFunc("POST /v2/end", c.takeEnd)
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		refuse(w, http.StatusNotFound, "This computer's door takes only POST /v2/answer, /v2/arrived and /v2/end.")
	})
	return mux
}

func refuse(w http.ResponseWriter, status int, sentence string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	io.WriteString(w, sentence)
}

func replyLease(w http.ResponseWriter, lease *pb.Lease) {
	raw, _ := proto.Marshal(lease)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(raw)
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
}

// refused is an answer the door will not take, with the sentence it says.
type refused struct {
	status   int
	sentence string
}

func (r refused) Error() string { return r.sentence }

func body(r *http.Request, message proto.Message) error {
	raw, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return err
	}
	return proto.Unmarshal(raw, message)
}

// freshMembers is the newest Members this computer can have now: it asks the
// Mac first, within half a second, so a device removed a moment ago is
// refused, and goes on with what it holds if the Mac does not answer.
func (c *Client) freshMembers(ctx context.Context) (*pb.Members, error) {
	current, err := c.refresh(ctx, automaticLimit)
	if err != nil {
		return nil, err
	}
	return current.members, nil
}

func (c *Client) takeAnswer(w http.ResponseWriter, r *http.Request) {
	upload := &pb.AnswerUpload{}
	if body(r, upload) != nil || (upload.Answer == nil && upload.DenyRequestId == "") {
		refuse(w, http.StatusBadRequest, "The body must be an AnswerUpload: a signed answer, or a plain denial.")
		return
	}
	answer := &pb.Answer{}
	if upload.Answer != nil && (proto.Unmarshal(upload.Answer.Payload, answer) != nil || answer.Domain != keyring.AnswerDomain) {
		refuse(w, http.StatusBadRequest, "The signed answer is not an Answer.")
		return
	}
	members, err := c.freshMembers(r.Context())
	if err != nil {
		refuse(w, http.StatusServiceUnavailable, "This computer could not read its own state. Try again.")
		return
	}
	now := time.Now()
	var lease *pb.Lease
	var id string
	taken := false
	err = c.Store.Update(r.Context(), func(state *clientstate.State) error {
		var saved *clientstate.ExpectedRequest
		var choice pb.Choice
		var answeredBy, reply string
		var notAfter int64
		var approval []byte
		if upload.Answer == nil {
			saved, choice = expected(state, upload.DenyRequestId), pb.Choice_CHOICE_DENY
			if saved == nil {
				return refused{http.StatusForbidden, "No request of this computer has that id."}
			}
		} else {
			for _, candidate := range state.Requests {
				signed := &pb.Signed{}
				if proto.Unmarshal(candidate.Request, signed) == nil && bytes.Equal(keyring.SHA256(signed.Payload), answer.RequestSha256) {
					saved = candidate
				}
			}
			if saved == nil {
				return refused{http.StatusForbidden, "No request of this computer has these exact bytes: it was changed, or it is not this computer's."}
			}
			choice = answer.Choice
			signer, err := keyring.Verify(upload.Answer, members, choice == pb.Choice_CHOICE_DENY)
			if err != nil {
				return refused{http.StatusForbidden, "This answer is not signed by a device in the user's list of devices: the device was removed, or never added."}
			}
			signed := &pb.Signed{}
			proto.Unmarshal(saved.Request, signed)
			full := &pb.Approval{Request: signed.Payload, Answer: upload.Answer, Delivery: upload.Delivery}
			switch choice {
			case pb.Choice_CHOICE_APPROVE:
				if _, err := keyring.OpenApproval(full, members, c.receiving, now); err != nil {
					return refused{http.StatusForbidden, "This approval could not be checked or opened by this computer: " + err.Error() + "."}
				}
				notAfter = answer.NotAfterUnixSeconds
			case pb.Choice_CHOICE_DENY:
				reply = answer.Reply
			default:
				return refused{http.StatusBadRequest, "An answer approves or denies."}
			}
			answeredBy = signer.Label
			approval, _ = proto.Marshal(full)
		}
		id = saved.LeaseId
		if saved.Lease.State != pb.LeaseState_LEASE_STATE_WAITING {
			lease = proto.Clone(saved.Lease).(*pb.Lease) // The first answer won.
			return nil
		}
		if now.Unix() >= saved.Lease.AnswerByUnixSeconds {
			saved.Lease.State = pb.LeaseState_LEASE_STATE_UNANSWERED
		} else if choice == pb.Choice_CHOICE_APPROVE {
			saved.Lease.State, saved.Lease.NotAfterUnixSeconds = pb.LeaseState_LEASE_STATE_APPROVED, notAfter
			releaseHold(state, saved.Scope.LoginId)
		} else {
			saved.Lease.State = pb.LeaseState_LEASE_STATE_DENIED
			saved.Lease.RetryNotBeforeUnixSeconds = holdOff(state, saved.Scope.LoginId, reply, now)
		}
		if saved.Lease.State != pb.LeaseState_LEASE_STATE_UNANSWERED {
			saved.Lease.AnsweredBy, saved.Lease.Reply, saved.Approval = answeredBy, reply, approval
		}
		lease, taken = proto.Clone(saved.Lease).(*pb.Lease), true
		return nil
	})
	var no refused
	if errors.As(err, &no) {
		c.log("answer refused id=" + id + " reason=" + strconv.Quote(no.sentence))
		refuse(w, no.status, no.sentence)
		return
	}
	if err != nil {
		refuse(w, http.StatusServiceUnavailable, "This computer could not save the answer. Try again.")
		return
	}
	replyLease(w, lease)
	if taken {
		c.log("answer id=" + id + " state=" + lease.State.String() + " by=" + strconv.Quote(lease.AnsweredBy))
		c.pushAll(context.WithoutCancel(r.Context()), id)
	}
}

// takeArrival records that a request reached a device, for the screens to
// say so: signed by the device's reply key, or unsigned naming the SHA-256 of
// the push address it came to. A timing note that grants nothing.
func (c *Client) takeArrival(w http.ResponseWriter, r *http.Request) {
	signed, arrival := &pb.Signed{}, &pb.Arrival{}
	if body(r, signed) != nil || proto.Unmarshal(signed.Payload, arrival) != nil || arrival.Domain != keyring.ArrivalDomain {
		refuse(w, http.StatusBadRequest, "The body must be a signed Arrival.")
		return
	}
	state, err := c.Store.Load(r.Context())
	if err != nil {
		refuse(w, http.StatusServiceUnavailable, "This computer could not read its own state. Try again.")
		return
	}
	current, err := held(state)
	if err != nil {
		refuse(w, http.StatusServiceUnavailable, "This computer could not read its own state. Try again.")
		return
	}
	device, err := keyring.Verify(signed, current.members, true)
	if err != nil {
		device = current.device(arrival.DeviceKeyId)
		registration := current.registrations[arrival.DeviceKeyId]
		if device == nil || registration == nil || !bytes.Equal(arrival.PushTokenSha256, keyring.SHA256(registration.ApnsToken)) {
			refuse(w, http.StatusForbidden, "An arrival is signed by the device it reached, or names its push address.")
			return
		}
	}
	if device.KeyId != arrival.DeviceKeyId {
		refuse(w, http.StatusForbidden, "An arrival comes from the device it reached.")
		return
	}
	first := false
	err = c.Store.Update(r.Context(), func(state *clientstate.State) error {
		saved := expected(state, arrival.RequestId)
		if saved == nil {
			return refused{http.StatusForbidden, "No request of this computer has that id."}
		}
		if saved.Lease.ArrivedUnixSeconds == 0 {
			saved.Lease.ArrivedUnixSeconds, saved.Lease.ArrivedOn, first = time.Now().Unix(), device.Label, true
		}
		return nil
	})
	var no refused
	if errors.As(err, &no) {
		refuse(w, no.status, no.sentence)
		return
	}
	if first {
		c.log("arrived id=" + arrival.RequestId + " device=" + strconv.Quote(device.Label))
	}
	w.WriteHeader(http.StatusOK)
}

// takeEnd is Stop: a device ends an approved request at once, signed by its
// reply key. Anything else is left as it is and its state returned.
func (c *Client) takeEnd(w http.ResponseWriter, r *http.Request) {
	signed, end := &pb.Signed{}, &pb.EndRequest{}
	if body(r, signed) != nil || proto.Unmarshal(signed.Payload, end) != nil || end.Domain != keyring.EndDomain {
		refuse(w, http.StatusBadRequest, "The body must be a signed EndRequest.")
		return
	}
	members, err := c.freshMembers(r.Context())
	if err != nil {
		refuse(w, http.StatusServiceUnavailable, "This computer could not read its own state. Try again.")
		return
	}
	device, err := checkEnd(signed, members)
	if err != nil {
		refuse(w, http.StatusForbidden, "Stop is signed by the reply key of a device in the user's list of devices.")
		return
	}
	lease, stopped, err := c.endByStop(r.Context(), end.RequestId, device, "door")
	var no refused
	if errors.As(err, &no) {
		refuse(w, no.status, no.sentence)
		return
	}
	if err != nil {
		refuse(w, http.StatusServiceUnavailable, "This computer could not save the Stop. Try again.")
		return
	}
	replyLease(w, lease)
	if stopped {
		c.pushAll(context.WithoutCancel(r.Context()), end.RequestId)
	}
}

// checkEnd accepts a Stop signed by the reply key of a device in members,
// naming that device.
func checkEnd(signed *pb.Signed, members *pb.Members) (*pb.Device, error) {
	end := &pb.EndRequest{}
	if proto.Unmarshal(signed.GetPayload(), end) != nil || end.Domain != keyring.EndDomain {
		return nil, keyring.ErrWrongDomain
	}
	device, err := keyring.Verify(signed, members, true)
	if err != nil {
		return nil, err
	}
	if signed.SignerKeyId != device.ReplyKeyId || end.DeviceKeyId != device.KeyId {
		return nil, keyring.ErrNotAllowed
	}
	return device, nil
}

// endByStop ends an approved request at once, as Josh's Stop on device.
// Anything else is left as it is. `via` says in the log how the Stop came: at
// the door, or left at the Mac. Returns the request's Lease, and whether it
// moved, in which case the caller tells the devices (pushAll).
func (c *Client) endByStop(ctx context.Context, requestID string, device *pb.Device, via string) (*pb.Lease, bool, error) {
	var lease *pb.Lease
	stopped := false
	err := c.Store.Update(ctx, func(state *clientstate.State) error {
		saved := expected(state, requestID)
		if saved == nil {
			return refused{http.StatusForbidden, "No request of this computer has that id."}
		}
		if saved.Lease.State == pb.LeaseState_LEASE_STATE_APPROVED {
			saved.Lease.State, saved.Lease.EndedBy, saved.Approval, stopped = pb.LeaseState_LEASE_STATE_ENDED, device.Label, nil, true
		}
		lease = proto.Clone(saved.Lease).(*pb.Lease)
		return nil
	})
	if err != nil {
		return nil, false, err
	}
	if stopped {
		c.log("stopped id=" + requestID + " by=" + strconv.Quote(device.Label) + " via=" + via)
	}
	return lease, stopped, nil
}
