// Written by AI on 2026.11.26 by model gemini-4-neon; updated 2026.11.27 by model gemini-4-hydrogen.
package remote

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

func TestPushPayloadPerDeviceFallbackCategoryAndAutomaticSilence(t *testing.T) {
	const mac = pb.DeviceKind_DEVICE_KIND_MAC
	const phone = pb.DeviceKind_DEVICE_KIND_IPHONE
	const watch = pb.DeviceKind_DEVICE_KIND_WATCH
	const one = float64(1)
	for _, test := range []struct {
		name      string
		device    pb.DeviceKind
		waiting   bool
		automatic bool
		alert     bool
		required  map[string]any
		absent    []string
	}{
		{"iPhone waiting", phone, true, false, true, map[string]any{"category": "REQUEST", "mutable-content": one}, nil},
		{"Watch waiting", watch, true, false, true, map[string]any{"category": "WATCH_REQUEST", "mutable-content": one}, nil},
		{"Mac waiting", mac, true, false, false, nil, []string{"category", "alert"}},
		{"iPhone outcome", phone, false, false, true, map[string]any{"interruption-level": "passive", "mutable-content": one, "content-available": one}, []string{"category", "sound"}},
		{"Watch outcome", watch, false, false, true, map[string]any{"interruption-level": "passive"}, []string{"category"}},
		{"Mac outcome", mac, false, false, false, map[string]any{"content-available": one}, []string{"alert"}},
		{"iPhone automatic", phone, false, true, false, map[string]any{"content-available": one}, []string{"alert", "interruption-level"}},
		{"Watch automatic", watch, false, true, false, map[string]any{"content-available": one}, []string{"alert", "interruption-level"}},
		{"Mac automatic", mac, false, true, false, map[string]any{"content-available": one}, []string{"alert", "interruption-level"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			raw := pushPayload("req-1", &pb.Notice{}, test.waiting, test.automatic, test.device)
			assertAPS(t, raw, test.required, test.absent)
			if got := usesAlertTransport(test.waiting, test.automatic, test.device); got != test.alert {
				t.Errorf("alert transport = %t, want %t", got, test.alert)
			}
		})
	}
}

func assertAPS(t *testing.T, raw []byte, required map[string]any, absent []string) {
	t.Helper()
	var body struct {
		APS map[string]any `json:"aps"`
	}
	if err := json.Unmarshal(raw, &body); err != nil || body.APS == nil {
		t.Fatalf("missing or invalid aps object in %s: %v", raw, err)
	}
	for key, want := range required {
		if got := body.APS[key]; got != want {
			t.Errorf("aps[%q] = %v, want %v", key, got, want)
		}
	}
	for _, key := range absent {
		if got, present := body.APS[key]; present {
			t.Errorf("aps[%q] = %v, want absent", key, got)
		}
	}
}

type capturedPush struct {
	token    string
	pushType string
	priority string
	body     []byte
}

func TestPushAllAutomaticSilentNoLoginAndInvalidTokenPruning(t *testing.T) {
	var mu sync.Mutex
	var captured []capturedPush

	phoneToken := []byte("11111111111111111111111111111111")
	watchToken := []byte("22222222222222222222222222222222")
	watchTokenHex := hex.EncodeToString(watchToken)

	rejectWatch := false
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		tok := r.Header.Get("x-akr-token")
		mu.Lock()
		reject := rejectWatch && tok == watchTokenHex
		if !reject {
			captured = append(captured, capturedPush{
				token:    tok,
				pushType: r.Header.Get("apns-push-type"),
				priority: r.Header.Get("apns-priority"),
				body:     body,
			})
		}
		mu.Unlock()
		if reject {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"reason":"BadDeviceToken"}`))
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer relay.Close()
	t.Setenv("AGENT_KEYRING_PUSH_RELAY_URL", relay.URL)

	client, phone, watch := preparePushTest(t, phoneToken, watchToken)
	if err := client.pushAll(context.Background(), "req-auto-1"); err != nil {
		t.Fatalf("pushAll automatic: %v", err)
	}
	mu.Lock()
	received := captured
	mu.Unlock()
	assertSilentPushes(t, received, phone, watch)

	// Now reject Watch with BadDeviceToken on a waiting push: Watch registration must be pruned.
	mu.Lock()
	rejectWatch = true
	captured = nil
	mu.Unlock()
	if err := client.pushAll(context.Background(), "req-wait-1"); err != nil {
		t.Fatalf("pushAll with one valid and one invalid token: %v", err)
	}
	assertPrunedPushRegistration(t, client, phone.id, watch.id)

	// Transport failure (relay closed) must not report "(status 0 )".
	relay.Close()
	err := client.pushAll(context.Background(), "req-wait-1")
	if err == nil {
		t.Fatal("expected error when relay is closed")
	}
	if strings.Contains(err.Error(), "status 0") {
		t.Fatalf("transport error must not format status 0: %v", err)
	}
	if !strings.Contains(err.Error(), "APNs transport failed:") {
		t.Fatalf("expected wrapped transport error in %v", err)
	}
}

type pushOpener struct {
	token string
	id    string
	key   *ecdh.PrivateKey
}

func preparePushTest(t *testing.T, phoneToken, watchToken []byte) (*RemoteKeyringClient, pushOpener, pushOpener) {
	t.Helper()
	macSign, _, macDev := testDevice(t, "Mac")
	macDev.Kind = pb.DeviceKind_DEVICE_KIND_MAC
	_, phoneReply, phoneDev := testDevice(t, "iPhone")
	phoneDev.Kind = pb.DeviceKind_DEVICE_KIND_IPHONE
	_, _, watchDev := testDevice(t, "Watch")
	watchDev.Kind = pb.DeviceKind_DEVICE_KIND_WATCH

	phoneNoticeKey, _ := ecdh.P256().GenerateKey(rand.Reader)
	watchNoticeKey, _ := ecdh.P256().GenerateKey(rand.Reader)
	tlsKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	recvKey, _ := ecdh.P256().GenerateKey(rand.Reader)
	spki, _ := x509.MarshalPKIXPublicKey(&tlsKey.PublicKey)
	machineID := keyring.DeriveKeyID(spki)

	members := &pb.Members{
		Domain:   keyring.MembersDomain,
		Revision: 1,
		Devices:  []*pb.Device{macDev, phoneDev, watchDev},
		Machines: []*pb.Machine{{MachineId: machineID, Label: "Linux", TlsPublicKey: spki, ReceivingPublicKey: recvKey.PublicKey().Bytes()}},
	}
	regPhone := testSign(t, phoneReply, &pb.PushRegistration{
		Domain: keyring.PushDomain, DeviceKeyId: phoneDev.KeyId, ApnsToken: phoneToken,
		ApnsTopic: "com.example.phone", NoticePublicKey: phoneNoticeKey.PublicKey().Bytes(), RegisteredUnixSeconds: 100,
	})
	regWatch := testSign(t, phoneReply, &pb.PushRegistration{
		Domain: keyring.PushDomain, DeviceKeyId: watchDev.KeyId, ApnsToken: watchToken,
		ApnsTopic: "com.example.watch", NoticePublicKey: watchNoticeKey.PublicKey().Bytes(), RegisteredUnixSeconds: 100,
	})
	cat := testSign(t, macSign, &pb.Catalogue{
		Domain:   keyring.CatalogueDomain,
		Revision: 1,
		Logins:   []*pb.Login{{LoginId: "login-1", Title: "VeryLongTitle", Sites: []string{"https://example.com"}, Account: "a@b.c", Rule: pb.Rule_RULE_AUTOMATIC, Version: 1}},
	})
	bundleRaw, _ := proto.Marshal(&pb.Bundle{
		Catalogue:         cat,
		PushRegistrations: []*pb.Signed{regPhone, regWatch},
	})
	membersRaw, _ := proto.Marshal(testSign(t, macSign, members))

	store := clientstate.ClientStateStore{Directory: filepath.Join(t.TempDir(), "state")}
	if err := store.UpdateClientState(context.Background(), func(st *clientstate.State) error {
		st.RecipientId = machineID
		st.Members = membersRaw
		st.Bundle = bundleRaw
		st.Requests = pushTestRequests(t, tlsKey, machineID)

		return nil
	}); err != nil {
		t.Fatal(err)
	}

	client := &RemoteKeyringClient{Store: store, receiving: recvKey, label: "Linux"}
	return client,
		pushOpener{hex.EncodeToString(phoneToken), phoneDev.KeyId, phoneNoticeKey},
		pushOpener{hex.EncodeToString(watchToken), watchDev.KeyId, watchNoticeKey}
}

func pushTestRequests(t *testing.T, tlsKey *ecdsa.PrivateKey, machineID string) []*clientstate.ExpectedRequest {
	t.Helper()
	autoReq := &pb.Request{
		Domain:              keyring.RequestDomain,
		RequestId:           "req-auto-1",
		LoginId:             "login-1",
		MachineId:           machineID,
		Reason:              "Nightly job",
		AskedUnixSeconds:    time.Now().Unix(),
		AnswerByUnixSeconds: time.Now().Add(10 * time.Minute).Unix(),
		Automatic:           true,
		AnswerBoxId:         "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		AnswerBoxKey:        make([]byte, 32),
	}
	signedAuto, err := keyring.SignRequest(autoReq, keyring.NewSoftwarePayloadSigner(tlsKey))
	if err != nil {
		t.Fatal(err)
	}
	signedAutoRaw, _ := proto.Marshal(signedAuto)

	waitReq := proto.Clone(autoReq).(*pb.Request)
	waitReq.RequestId = "req-wait-1"
	waitReq.Automatic = false
	signedWait, err := keyring.SignRequest(waitReq, keyring.NewSoftwarePayloadSigner(tlsKey))
	if err != nil {
		t.Fatal(err)
	}
	signedWaitRaw, _ := proto.Marshal(signedWait)

	return []*clientstate.ExpectedRequest{
		{
			LeaseId: "req-auto-1",
			Request: signedAutoRaw,
			Lease: &pb.Lease{
				RequestId: "req-auto-1", LoginId: "login-1", State: pb.LeaseState_LEASE_STATE_APPROVED,
				Automatic: true, AnswerByUnixSeconds: autoReq.AnswerByUnixSeconds, NotAfterUnixSeconds: time.Now().Add(30 * time.Minute).Unix(),
			},
		},
		{
			LeaseId: "req-wait-1",
			Request: signedWaitRaw,
			Lease: &pb.Lease{
				RequestId: "req-wait-1", LoginId: "login-1", State: pb.LeaseState_LEASE_STATE_WAITING,
				AnswerByUnixSeconds: waitReq.AnswerByUnixSeconds,
			},
		},
	}
}

func assertSilentPushes(t *testing.T, captured []capturedPush, phone, watch pushOpener) {
	t.Helper()
	if len(captured) != 2 {
		t.Fatalf("got %d automatic pushes, want 2", len(captured))
	}
	for _, p := range captured {
		if p.pushType != "background" || p.priority != "5" {
			t.Errorf("automatic push token=%s got type=%q priority=%q, want background/5", p.token, p.pushType, p.priority)
		}
		var body struct {
			APS map[string]any `json:"aps"`
			Akr string         `json:"akr"`
		}
		if err := json.Unmarshal(p.body, &body); err != nil {
			t.Fatal(err)
		}
		if _, hasAlert := body.APS["alert"]; hasAlert {
			t.Errorf("automatic push carried alert: %v", body.APS["alert"])
		}
		rawNotice, _ := base64.StdEncoding.DecodeString(body.Akr)
		notice := &pb.Notice{}
		if err := proto.Unmarshal(rawNotice, notice); err != nil {
			t.Fatal(err)
		}
		openerKey, openerID := phone.key, phone.id
		if p.token == watch.token {
			openerKey, openerID = watch.key, watch.id
		}
		work, err := keyring.OpenNotice(notice, openerKey, openerID)
		if err != nil {
			t.Fatalf("OpenNotice: %v", err)
		}
		if work.Login != nil {
			t.Errorf("work.Login must not be populated on push, got %+v", work.Login)
		}
	}
	if captured[0].token != phone.token && captured[1].token != phone.token {
		t.Fatalf("expected phone token %s in captured pushes", phone.token)
	}
}

func assertPrunedPushRegistration(t *testing.T, client *RemoteKeyringClient, phoneID, watchID string) {
	t.Helper()
	st, err := client.Store.LoadClientState(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	v, err := loadSavedCatalogueView(st)
	if err != nil {
		t.Fatal(err)
	}
	if _, hasPhone := v.registrations[phoneID]; !hasPhone {
		t.Fatal("valid phone registration was pruned")
	}
	if _, hasWatch := v.registrations[watchID]; hasWatch {
		t.Fatal("invalid watch registration was not pruned from state.Bundle")
	}
}
