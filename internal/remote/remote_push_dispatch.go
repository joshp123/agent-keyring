// Written by AI on 2026.11.21 by model claude opus 5.5; telling the Mac's door cut on 2026.11.24.
package remote

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"slices"
	"strconv"
	"sync"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/apns"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

// pushRelayURL returns the blind APNs push-signing relay URL to use when no
// local .p8 push credential is present. Explicit "none" disables it; loopback
// tests keep it off unless AGENT_KEYRING_PUSH_RELAY_URL is explicitly set.
func pushRelayURL() string {
	if raw, ok := os.LookupEnv("AGENT_KEYRING_PUSH_RELAY_URL"); ok {
		if raw == "" || raw == "none" || raw == "off" {
			return ""
		}
		return raw
	}
	if loopbackTest() {
		return ""
	}
	return apns.DefaultRelayURL
}

// canPush says, before anything is asked, why a request could not reach
// any device that approves: an iPhone, Apple Watch or Mac with a push address.
func (c *RemoteKeyringClient) canPush(state *clientstate.State, current *remoteCatalogueView) error {
	if len(state.PushCredential) == 0 && pushRelayURL() == "" {
		return errors.New("This computer has no push credential from the Mac, so its requests cannot reach the user's iPhone or Apple Watch. Give the Mac the push key, then enrol this computer again.")
	}
	if len(collectPushDeviceTargets(current)) == 0 {
		return errors.New("No device in the user's list has a push address yet, so nobody can be asked. Open Agent Keyring on the iPhone, then ask again.")
	}
	return nil
}

type pushDeviceTarget struct {
	device       *pb.Device
	registration *pb.PushRegistration
}

// collectPushDeviceTargets is every device that may approve and has a push address, of any kind.
func collectPushDeviceTargets(current *remoteCatalogueView) []pushDeviceTarget {
	var found []pushDeviceTarget
	for keyID, registration := range current.registrations {
		if device := current.findCatalogueDevice(keyID); device != nil {
			found = append(found, pushDeviceTarget{device, registration})
		}
	}
	return found
}

// buildDevicePushSender is Apple's push service when this computer holds a local .p8 push
// credential, or the stateless blind push-signing relay (https://push.opentrawl.sh)
// otherwise. A loopback test may point it at a stand-in for Apple.
func (c *RemoteKeyringClient) buildDevicePushSender(state *clientstate.State) (*apns.PushNotificationSender, error) {
	if len(state.PushCredential) == 0 {
		relay := pushRelayURL()
		if relay == "" {
			return nil, errors.New("This computer has no push credential from the Mac.")
		}
		return apns.NewRelayPushSender(relay, apns.PushSenderConfig{TestCA: os.Getenv("AGENT_KEYRING_TEST_APNS_CA")})
	}
	sealed := &pb.SealedPushCredential{}
	if proto.Unmarshal(state.PushCredential, sealed) != nil {
		return nil, errors.New("This computer has no push credential from the Mac.")
	}
	credential, err := keyring.OpenPushCredential(sealed, c.receiving)
	if err != nil {
		return nil, errors.New("This computer cannot open its push credential. Enrol it again.")
	}
	defer clear(credential.PrivateKey)
	config := apns.PushSenderConfig{KeyID: credential.KeyId, TeamID: credential.TeamId}
	if gateway := os.Getenv("AGENT_KEYRING_TEST_APNS_GATEWAY"); gateway != "" {
		parsed, err := url.Parse(gateway)
		ip, ipErr := netip.ParseAddr(parsed.Hostname())
		if err != nil || ipErr != nil || !loopbackTest() || !ip.IsLoopback() {
			return nil, errors.New("AGENT_KEYRING_TEST_APNS_GATEWAY is only for loopback tests.")
		}
		config.TestGateway, config.TestCA = gateway, os.Getenv("AGENT_KEYRING_TEST_APNS_CA")
	}
	return apns.NewPushSenderWithKey(credential.PrivateKey, config)
}

// pushAll sends one push to every device for a request, with the request as
// it is now: a visible one while it waits, and a silent one for every
// outcome, so the devices take the notification away. A Mac's push is always
// silent: it shows a waiting request in its own panel. An Automatic use is
// silent from the start, so the devices show it in use and can stop it. It
// fails only if Apple took no push for a waiting request.
func (c *RemoteKeyringClient) pushAll(ctx context.Context, leaseID string) error {
	state, err := c.Store.LoadClientState(ctx)
	if err != nil {
		return err
	}
	saved := findSavedLeaseRequest(state, leaseID)
	current, err := loadSavedCatalogueView(state)
	if err != nil || saved == nil {
		return errors.New("This computer has no request with that ID.")
	}
	sender, err := c.buildDevicePushSender(state)
	if err != nil {
		return err
	}
	if state.ApnsToken != "" {
		sender.SetPushAuthToken(state.ApnsToken, time.Unix(state.ApnsTokenIssuedUnixSeconds, 0))
	}
	signed := &pb.Signed{}
	if err := proto.Unmarshal(saved.Request, signed); err != nil {
		return fmt.Errorf("saved push request unreadable: %w", err)
	}
	request, err := keyring.ParseLeaseRequestPayload(signed.Payload)
	if err != nil {
		return err
	}
	waiting := saved.Lease.State == pb.LeaseState_LEASE_STATE_WAITING
	automatic := request.GetAutomatic()
	expires := saved.Lease.AnswerByUnixSeconds
	if !waiting {
		expires = time.Now().Add(time.Hour).Unix()
	}
	envelope := &pb.SignedRequestEnvelope{Request: signed.Payload, RequestSignature: signed.Signature}
	if !waiting {
		envelope.Outcome = proto.CloneOf(saved.Lease)
		envelope.Outcome.AuthorityContext = nil
	}
	results := sendPushes(ctx, sender, collectPushDeviceTargets(current), pushMessage{envelope, leaseID, expires, automatic})
	accepted, failures, invalidTokens := c.logPushResults(leaseID, waiting, results)
	c.savePushResults(ctx, state, sender, leaseID, accepted && waiting, invalidTokens)
	if !accepted && len(failures) > 0 {
		return fmt.Errorf("The request could not reach the user's devices: %v", failures)
	}
	return nil
}

type sentPush struct {
	label        string
	deviceKeyID  string
	apnsToken    []byte
	invalidToken bool
	reason       string
	err          error
}

type pushMessage struct {
	envelope  *pb.SignedRequestEnvelope
	leaseID   string
	expires   int64
	automatic bool
}

func sendPushes(ctx context.Context, sender *apns.PushNotificationSender, devices []pushDeviceTarget, message pushMessage) <-chan sentPush {
	results := make(chan sentPush, len(devices))
	var wg sync.WaitGroup
	for _, device := range devices {
		wg.Go(func() {
			results <- sendPush(ctx, sender, device, message)
		})
	}
	wg.Wait()
	close(results)
	return results
}

func sendPush(ctx context.Context, sender *apns.PushNotificationSender, target pushDeviceTarget, message pushMessage) sentPush {
	device, registration := target.device, target.registration
	sent := sentPush{label: device.Label, deviceKeyID: device.KeyId, apnsToken: registration.ApnsToken}
	notice, err := keyring.SealNotice(message.envelope, registration.NoticePublicKey, device.KeyId)
	if err != nil {
		sent.err = err
		return sent
	}
	waiting := message.envelope.Outcome == nil
	// The Mac panel and automatic starts use silent pushes. Other devices
	// use alert transport so passive outcomes can replace waiting alerts.
	alert := usesAlertTransport(waiting, message.automatic, device.Kind)
	payload := pushPayload(message.leaseID, notice, waiting, message.automatic, device.Kind)
	if len(payload) > 4096 {
		sent.err = fmt.Errorf("the notification would be %d bytes, over Apple's 4096; shorten the reason", len(payload))
		return sent
	}
	result, err := sender.SendPushNotification(ctx, registration.ApnsToken, registration.ApnsTopic, registration.ApnsProduction, message.leaseID, message.expires, payload, alert)
	if err != nil {
		if result.Status != 0 {
			sent.err = fmt.Errorf("Apple did not take it (status %d %s)", result.Status, result.Reason)
		} else {
			sent.err = fmt.Errorf("Apple did not take it: %w", err)
		}
	}
	sent.invalidToken, sent.reason = result.InvalidToken, result.Reason
	return sent
}

func (c *RemoteKeyringClient) logPushResults(leaseID string, waiting bool, results <-chan sentPush) (bool, []string, map[string][]byte) {
	var failures []string
	accepted := false
	invalidTokens := map[string][]byte{}
	for r := range results {
		if r.err != nil {
			failures = append(failures, r.label+": "+r.err.Error())
			c.appendRemoteEventLog("push not delivered id=" + leaseID + " device=" + strconv.Quote(r.label) + " visible=" + strconv.FormatBool(waiting) + " error=" + strconv.Quote(r.err.Error()))
			if r.invalidToken {
				invalidTokens[r.deviceKeyID] = r.apnsToken
				c.appendRemoteEventLog("push address gone device=" + strconv.Quote(r.label) + " reason=" + strconv.Quote(r.reason))
			}
			continue
		}
		accepted = true
		c.appendRemoteEventLog("push accepted by Apple id=" + leaseID + " device=" + strconv.Quote(r.label) + " visible=" + strconv.FormatBool(waiting))
	}
	return accepted, failures, invalidTokens
}

func (c *RemoteKeyringClient) savePushResults(ctx context.Context, state *clientstate.State, sender *apns.PushNotificationSender, leaseID string, pushed bool, invalidTokens map[string][]byte) {
	token, issued := sender.ReadCachedPushToken()
	if !pushed && token == state.ApnsToken && len(invalidTokens) == 0 {
		return
	}
	err := c.Store.UpdateClientState(ctx, func(state *clientstate.State) error {
		if s := findSavedLeaseRequest(state, leaseID); s != nil && s.Lease.PushedUnixSeconds == 0 && pushed {
			s.Lease.PushedUnixSeconds = time.Now().Unix()
		}
		if token != "" && issued.Unix() > state.ApnsTokenIssuedUnixSeconds {
			state.ApnsToken, state.ApnsTokenIssuedUnixSeconds = token, issued.Unix()
		}
		if len(invalidTokens) > 0 {
			pruneInvalidRegistrations(state, invalidTokens)
		}
		return nil
	})
	if err != nil {
		// Delivery already happened. A failed bookkeeping write must never
		// make the caller remove the request as unsent.
		c.appendRemoteEventLog("push status not saved id=" + leaseID + " error=" + strconv.Quote(err.Error()))
	}
}

func (c *RemoteKeyringClient) pushOutcome(ctx context.Context, leaseID string) {
	if err := c.pushAll(ctx, leaseID); err != nil {
		c.appendRemoteEventLog("outcome push failed id=" + leaseID + " error=" + strconv.Quote(err.Error()))
	}
}

func pruneInvalidRegistrations(state *clientstate.State, dead map[string][]byte) {
	if len(state.Bundle) == 0 || len(dead) == 0 {
		return
	}
	bundle := &pb.Bundle{}
	if proto.Unmarshal(state.Bundle, bundle) != nil || len(bundle.PushRegistrations) == 0 {
		return
	}
	before := len(bundle.PushRegistrations)
	bundle.PushRegistrations = slices.DeleteFunc(bundle.PushRegistrations, func(signed *pb.Signed) bool {
		reg := &pb.PushRegistration{}
		if proto.Unmarshal(signed.GetPayload(), reg) != nil {
			return false
		}
		badToken, ok := dead[reg.DeviceKeyId]
		return ok && bytes.Equal(reg.ApnsToken, badToken)
	})
	if len(bundle.PushRegistrations) != before {
		state.Bundle, _ = proto.Marshal(bundle)
	}
}

// usesAlertTransport reports whether APNs should send the push at priority 10
// with apns-push-type alert (for iPhone/Watch waiting requests and non-automatic
// outcome collapses) rather than priority 5 background (Mac and Automatic).
func usesAlertTransport(waiting, automatic bool, kind pb.DeviceKind) bool {
	if kind == pb.DeviceKind_DEVICE_KIND_MAC || automatic {
		return false
	}
	if kind == pb.DeviceKind_DEVICE_KIND_IPHONE || kind == pb.DeviceKind_DEVICE_KIND_WATCH {
		return true
	}
	return waiting
}

// pushCategory returns the per-device APNs fallback category for a visible
// waiting request push so a skipped Notification Service Extension still routes
// to the device's approval handler rather than a dead banner.
func pushCategory(kind pb.DeviceKind) string {
	switch kind {
	case pb.DeviceKind_DEVICE_KIND_IPHONE:
		return "REQUEST"
	case pb.DeviceKind_DEVICE_KIND_WATCH:
		return "WATCH_REQUEST"
	default:
		return ""
	}
}

// pushPayload is what Apple carries: nothing readable about the request.
// Apple refuses one over 4096 bytes. A non-automatic waiting push for
// iPhone/Watch is shown and sounded; a non-automatic outcome push for
// iPhone/Watch uses a passive collapse alert (priority 10, silent, no
// category); Mac and Automatic pushes stay silent background pushes.
func pushPayload(id string, notice *pb.Notice, waiting, automatic bool, kind pb.DeviceKind) []byte {
	aps := map[string]any{"content-available": 1, "thread-id": id}
	if !automatic && waiting && kind != pb.DeviceKind_DEVICE_KIND_MAC {
		aps = map[string]any{
			"alert":              map[string]string{"title": "Agent Keyring", "body": "A request is waiting."},
			"interruption-level": "time-sensitive",
			"mutable-content":    1,
			"thread-id":          id,
			"sound":              "default",
		}
		if category := pushCategory(kind); category != "" {
			aps["category"] = category
		}
	} else if !waiting && !automatic && (kind == pb.DeviceKind_DEVICE_KIND_IPHONE || kind == pb.DeviceKind_DEVICE_KIND_WATCH) {
		aps = map[string]any{
			"alert":              map[string]string{"title": "Agent Keyring", "body": "Request answered."},
			"interruption-level": "passive",
			"mutable-content":    1,
			"content-available":  1,
			"thread-id":          id,
		}
	}
	raw, _ := proto.Marshal(notice)
	payload, _ := json.Marshal(map[string]any{"aps": aps, "id": id, "akr": base64.StdEncoding.EncodeToString(raw)})
	return payload
}
