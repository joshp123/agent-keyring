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

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/apns"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/door"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"github.com/opentrawl/agent-keyring/internal/tlsid"
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
		return errors.New("This computer has no push credential from the Mac, so its requests cannot reach the user's iPhone or Apple Watch. Give the Mac the push key, then enrol this computer again.")
	}
	if len(targets(current)) == 0 {
		return errors.New("No iPhone or Apple Watch in the user's list of devices has a push address yet, so nobody can be asked. Open Agent Keyring on the iPhone, then ask again.")
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
// devices show it in use and can stop it. Beside the pushes, the Mac hears of
// every request that asks and of how it ended (tellMac). It fails only if
// neither Apple nor the Mac took a waiting request.
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
	if state.ApnsToken != "" {
		sender.UseToken(state.ApnsToken, time.Unix(state.ApnsTokenIssuedUnixSeconds, 0))
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
	macTook := false
	if !saved.Lease.Automatic {
		wg.Add(1)
		go func() { defer wg.Done(); macTook = c.tellMac(ctx, signed, saved.Lease, waiting) }()
	}
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
	token, issued := sender.Token()
	if (accepted && waiting) || token != state.ApnsToken {
		c.Store.Update(ctx, func(state *clientstate.State) error {
			if s := expected(state, leaseID); s != nil && s.Lease.PushedUnixSeconds == 0 && accepted && waiting {
				s.Lease.PushedUnixSeconds = time.Now().Unix()
			}
			if token != "" && issued.Unix() > state.ApnsTokenIssuedUnixSeconds {
				state.ApnsToken, state.ApnsTokenIssuedUnixSeconds = token, issued.Unix()
			}
			return nil
		})
	}
	if !accepted && !macTook && len(failures) > 0 {
		return fmt.Errorf("The request could not reach the user's devices: %v", failures)
	}
	return nil
}

// tellLimit is how long the Mac's door may take to hear of a request or its
// outcome. It runs beside the pushes, so a shut Mac costs an agent at most this.
const tellLimit = 2 * time.Second

// tellMac shows a waiting request on the Mac too (POST /v2/ask), where Josh
// answers it with Touch ID at this computer's door like any device, or tells
// the Mac how it ended (POST /v2/outcome), so its panel shows that and closes.
// True if the Mac took it.
func (c *Client) tellMac(ctx context.Context, signed *pb.Signed, lease *pb.Lease, waiting bool) bool {
	ctx, cancel := context.WithTimeout(ctx, tellLimit)
	defer cancel()
	path, body := "/v2/outcome", proto.Message(lease)
	if waiting {
		path, body = "/v2/ask", signed
	}
	if err := c.mac(ctx, "POST", path, body, nil); err != nil {
		c.log("mac not told id=" + lease.RequestId + " route=" + path + " error=" + strconv.Quote(err.Error()))
		return false
	}
	c.log("mac told id=" + lease.RequestId + " route=" + path)
	return true
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
