// Written by AI on 2026.11.21 by model claude opus 5.5.
package remote

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/apns"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/door"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"github.com/joshp123/agent-keyring/internal/tlsid"
	"google.golang.org/protobuf/proto"
)

func (c *Client) certificateSPKI() []byte {
	spki, _ := tlsid.SPKI(c.Certificate)
	return spki
}

// canPush says, before anything is asked, why a request could not reach
// Josh's iPhone or Apple Watch.
func (c *Client) canPush(state *clientstate.State, current *view) error {
	if len(state.PushCredential) == 0 {
		return errors.New("This computer has no push credential from the Mac, so its requests cannot reach Josh's iPhone or Apple Watch. Give the Mac the push key, then enrol this computer again.")
	}
	if len(targets(current)) == 0 {
		return errors.New("No iPhone or Apple Watch in Josh's list of devices has a push address yet, so nobody can be asked. Open Agent Keyring on the iPhone, then ask again.")
	}
	return nil
}

type target struct {
	device       *pb.Device
	registration *pb.PushRegistration
}

// targets is every device that may approve and has a push address.
func targets(current *view) []target {
	var found []target
	for keyID, registration := range current.registrations {
		if device := current.device(keyID); device != nil {
			found = append(found, target{device, registration})
		}
	}
	return found
}

// sender is Apple's push service, with the credential the Mac sealed to this
// computer. A loopback test may point it at a stand-in for Apple.
func (c *Client) sender(state *clientstate.State) (*apns.Sender, error) {
	sealed := &pb.SealedPushCredential{}
	if len(state.PushCredential) == 0 || proto.Unmarshal(state.PushCredential, sealed) != nil {
		return nil, errors.New("This computer has no push credential from the Mac.")
	}
	credential, err := keyring.OpenPushCredential(sealed, c.receiving)
	if err != nil {
		return nil, errors.New("This computer cannot open its push credential. Enrol it again.")
	}
	defer clear(credential.PrivateKey)
	config := apns.Config{KeyID: credential.KeyId, TeamID: credential.TeamId}
	if gateway := os.Getenv("AGENT_KEYRING_TEST_APNS_GATEWAY"); gateway != "" {
		parsed, err := url.Parse(gateway)
		if err != nil || !door.Testing() || door.CheckHost(parsed.Hostname()) != nil {
			return nil, errors.New("AGENT_KEYRING_TEST_APNS_GATEWAY is only for loopback tests.")
		}
		config.TestGateway, config.TestCA = gateway, os.Getenv("AGENT_KEYRING_TEST_APNS_CA")
	}
	return apns.NewWithKey(credential.PrivateKey, config)
}

// pushAll sends one push to every device for a request, with the request as
// it is now: a visible one while it waits (the Apple Watch's carrying its
// sealed copy), and a silent one for every outcome, so the devices take the
// notification away. An Automatic use is silent from the start, so the
// devices show it in use and can stop it.
func (c *Client) pushAll(ctx context.Context, leaseID string) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	saved := expected(state, leaseID)
	current, err := held(state)
	if err != nil || saved == nil {
		return errors.New("This computer has no request with that ID.")
	}
	sender, err := c.sender(state)
	if err != nil {
		return err
	}
	signed := &pb.Signed{}
	proto.Unmarshal(saved.Request, signed)
	request, _ := keyring.ParseRequest(signed.Payload)
	waiting := saved.Lease.State == pb.LeaseState_LEASE_STATE_WAITING
	expires := saved.Lease.AnswerByUnixSeconds
	if !waiting {
		expires = time.Now().Add(time.Hour).Unix()
	}
	type sent struct {
		label string
		err   error
	}
	results := make(chan sent, len(current.registrations))
	var wg sync.WaitGroup
	for _, t := range targets(current) {
		work := &pb.Work{Request: signed.Payload, RequestSignature: signed.Signature, Login: current.login(request.GetLoginId())}
		if waiting && t.device.Kind == pb.DeviceKind_DEVICE_KIND_WATCH {
			work.SealedLogin = current.copyFor(t.device.KeyId, request.GetLoginId())
		}
		if !waiting {
			work.Outcome = saved.Lease
		}
		notice, err := keyring.SealNotice(work, t.registration.NoticePublicKey, t.device.KeyId)
		if err != nil {
			results <- sent{t.device.Label, err}
			continue
		}
		payload := pushPayload(leaseID, notice, waiting)
		if len(payload) > 4096 {
			results <- sent{t.device.Label, fmt.Errorf("the notification would be %d bytes, over Apple's 4096; shorten the reason", len(payload))}
			continue
		}
		wg.Add(1)
		go func(t target) {
			defer wg.Done()
			result, err := sender.Send(ctx, t.registration.ApnsToken, t.registration.ApnsTopic, t.registration.ApnsProduction, leaseID, expires, payload, waiting)
			if err != nil {
				err = fmt.Errorf("Apple did not take it (status %d %s)", result.Status, result.Reason)
			}
			results <- sent{t.device.Label, err}
		}(t)
	}
	wg.Wait()
	close(results)
	var failures []string
	accepted := false
	for r := range results {
		if r.err != nil {
			failures = append(failures, r.label+": "+r.err.Error())
			c.log("push not delivered id=" + leaseID + " device=" + strconv.Quote(r.label) + " visible=" + strconv.FormatBool(waiting) + " error=" + strconv.Quote(r.err.Error()))
			continue
		}
		accepted = true
		c.log("push accepted by Apple id=" + leaseID + " device=" + strconv.Quote(r.label) + " visible=" + strconv.FormatBool(waiting))
	}
	if accepted && waiting {
		c.Store.Update(ctx, func(state *clientstate.State) error {
			if s := expected(state, leaseID); s != nil && s.Lease.PushedUnixSeconds == 0 {
				s.Lease.PushedUnixSeconds = time.Now().Unix()
			}
			return nil
		})
	}
	if !accepted && len(failures) > 0 {
		return fmt.Errorf("The request could not reach Josh's devices: %v", failures)
	}
	return nil
}

// pushPayload is what Apple carries: nothing readable about the request.
// Apple refuses one over 4096 bytes. `waiting`: a new request, shown and
// sounded; otherwise a silent push with the outcome for the app to act on.
func pushPayload(id string, notice *pb.Notice, waiting bool) []byte {
	aps := map[string]any{"content-available": 1, "thread-id": id}
	if waiting {
		aps = map[string]any{
			"alert":              map[string]string{"title": "Agent Keyring", "body": "A request is waiting."},
			"category":           "REQUEST",
			"interruption-level": "time-sensitive",
			"mutable-content":    1,
			"thread-id":          id,
			"sound":              "default",
		}
	}
	raw, _ := proto.Marshal(notice)
	payload, _ := json.Marshal(map[string]any{"aps": aps, "id": id, "akr": base64.StdEncoding.EncodeToString(raw)})
	return payload
}
