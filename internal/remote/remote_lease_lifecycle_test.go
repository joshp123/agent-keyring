// Written by AI on 2026.11.27 by model gemini-4-hydrogen.
package remote

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/box"
	"github.com/opentrawl/agent-keyring/internal/boxserver"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/keyring"
	"github.com/opentrawl/agent-keyring/internal/tlsid"
	"google.golang.org/protobuf/proto"
)

func startTestRelayBoxServer(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(boxserver.NewRelayBoxHandler(t.Context(), 1))
	t.Cleanup(server.Close)
	return server
}

func testSelfSignedCert(t *testing.T) (tls.Certificate, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
	spki, err := tlsid.ExtractCertificateSPKI(cert)
	if err != nil {
		t.Fatal(err)
	}
	return cert, spki
}

func testNewClientFixture(t *testing.T, relayURL string) (*RemoteKeyringClient, *ecdsa.PrivateKey, *ecdsa.PrivateKey, *pb.Device, *ecdsa.PrivateKey, *ecdsa.PrivateKey, *pb.Device, []byte) {
	t.Helper()
	t.Setenv("AGENT_KEYRING_TEST_LOOPBACK", "1")
	macSign, macReply, macDev := testDevice(t, "Mac")
	macDev.Kind = pb.DeviceKind_DEVICE_KIND_MAC
	phoneSign, phoneReply, phoneDev := testDevice(t, "iPhone")
	phoneDev.Kind = pb.DeviceKind_DEVICE_KIND_IPHONE

	cert, spki := testSelfSignedCert(t)
	recv, _ := ecdh.P256().GenerateKey(rand.Reader)
	machineID := keyring.DeriveKeyID(spki)
	members1 := &pb.Members{
		Domain:   keyring.MembersDomain,
		Revision: 1,
		Devices:  []*pb.Device{macDev, phoneDev},
		Machines: []*pb.Machine{{MachineId: machineID, Label: "Linux", TlsPublicKey: spki, ReceivingPublicKey: recv.PublicKey().Bytes()}},
	}
	signedMembers1 := testSign(t, macSign, members1)
	cat1 := testSign(t, macSign, &pb.Catalogue{
		Domain:   keyring.CatalogueDomain,
		Revision: 1,
		Logins:   []*pb.Login{{LoginId: "login-1", Title: "Example", Rule: pb.Rule_RULE_ASK, Version: 1}},
	})
	seed := make([]byte, 32)
	_, _ = rand.Read(seed)
	store := clientstate.ClientStateStore{Directory: filepath.Join(t.TempDir(), "state")}
	if err := store.UpdateClientState(context.Background(), func(st *clientstate.State) error {
		st.RecipientId = machineID
		st.MachineLabel = "Linux"
		st.BoxUrl = relayURL
		st.Members, _ = proto.Marshal(signedMembers1)
		st.Bundle, _ = proto.Marshal(&pb.Bundle{Catalogue: cat1})
		st.CatalogueRevision = 1
		st.Mailbox = &pb.UpdateMailbox{MachineId: machineID, Seed: seed, ReadAuth: box.GenerateBoxAuthToken()}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	client := &RemoteKeyringClient{Store: store, Certificate: cert, receiving: recv, label: "Linux"}
	return client, macSign, macReply, macDev, phoneSign, phoneReply, phoneDev, seed
}

func TestCheckStopInBoxRefreshesMembers(t *testing.T) {
	srv := startTestRelayBoxServer(t)
	client, macSign, _, macDev, _, _, phoneDev, seed := testNewClientFixture(t, srv.URL)
	_, watchReply, watchDev := testDevice(t, "Watch")
	watchDev.Kind = pb.DeviceKind_DEVICE_KIND_WATCH

	boxID, boxKey := box.GenerateBoxID()
	req := &pb.Request{
		Domain:              keyring.RequestDomain,
		RequestId:           "req-stop-1",
		LoginId:             "login-1",
		MachineId:           keyring.DeriveKeyID(func() []byte { s, _ := tlsid.ExtractCertificateSPKI(client.Certificate); return s }()),
		AskedUnixSeconds:    time.Now().Unix(),
		AnswerByUnixSeconds: time.Now().Add(10 * time.Minute).Unix(),
		AnswerBoxId:         boxID,
		AnswerBoxKey:        boxKey,
		AnswerBoxUrl:        srv.URL,
	}
	storeApprovedRequest(t, client, req)

	relay := box.NewRelayBoxClient(srv.URL)
	if err := relay.PublishLeaseGrantBox(context.Background(), boxID, boxKey, req.RequestId); err != nil {
		t.Fatal(err)
	}

	// Put Members rev 2 in Mac's mailbox adding Watch.
	members2 := &pb.Members{
		Domain:   keyring.MembersDomain,
		Revision: 2,
		Devices:  []*pb.Device{macDev, phoneDev, watchDev},
		Machines: []*pb.Machine{{MachineId: req.MachineId, Label: "Linux", TlsPublicKey: func() []byte { s, _ := tlsid.ExtractCertificateSPKI(client.Certificate); return s }(), ReceivingPublicKey: client.receiving.PublicKey().Bytes()}},
	}
	bundle2Raw, _ := proto.Marshal(&pb.Bundle{Members: testSign(t, macSign, members2)})
	mb, _ := client.Store.LoadClientState(context.Background())
	mailboxPut := box.RelayBoxPutOptions{TTL: box.TTLUpdate, Mode: box.ModeReplace, ReadAuth: mb.Mailbox.ReadAuth, WriteAuth: box.GenerateBoxAuthToken()}
	macSlot, mailboxKey := box.DeriveUpdateMailboxSlot(seed, macDev.KeyId), box.DeriveUpdateMailboxKey(seed)
	if err := relay.PutRelayBox(t.Context(), macSlot, mailboxKey, bundle2Raw, mailboxPut); err != nil {
		t.Fatal(err)
	}

	// Newly-added Watch signs Stop: checkStopInBox must refresh Members and accept it.
	endPayload, _ := proto.Marshal(&pb.EndRequest{Domain: keyring.EndDomain, RequestId: req.RequestId, DeviceKeyId: watchDev.KeyId, EndedUnixSeconds: time.Now().Unix()})
	signedEnd, err := keyring.SignKeyringDocument(endPayload, watchDev.ReplyKeyId, keyring.NewSoftwarePayloadSigner(watchReply))
	if err != nil {
		t.Fatal(err)
	}
	endRaw, _ := proto.Marshal(signedEnd)
	if stopped, err := relay.StopLeaseGrantBox(context.Background(), boxID, boxKey, req.RequestId, endRaw); err != nil || !stopped {
		t.Fatalf("Stop: stopped=%v err=%v", stopped, err)
	}
	if err := client.checkStopInBox(context.Background(), req.RequestId, req); err != nil {
		t.Fatalf("checkStopInBox refused newly-added device Stop: %v", err)
	}
	st, _ := client.Store.LoadClientState(context.Background())
	if got := findSavedLeaseRequest(st, req.RequestId).Lease.State; got != pb.LeaseState_LEASE_STATE_ENDED {
		t.Fatalf("lease state after Stop = %v, want ENDED", got)
	}

	// Remove Watch via Mac's mailbox and reject a Stop signed by its old reply key.
	members3 := &pb.Members{
		Domain:   keyring.MembersDomain,
		Revision: 3,
		Devices:  []*pb.Device{macDev, phoneDev},
		Machines: members2.Machines,
	}
	bundle3Raw, _ := proto.Marshal(&pb.Bundle{Members: testSign(t, macSign, members3)})
	if err := relay.PutRelayBox(t.Context(), macSlot, mailboxKey, bundle3Raw, mailboxPut); err != nil {
		t.Fatal(err)
	}
	boxID2, boxKey2 := box.GenerateBoxID()
	req2 := proto.Clone(req).(*pb.Request)
	req2.RequestId, req2.AnswerBoxId, req2.AnswerBoxKey = "req-stop-2", boxID2, boxKey2
	if err := relay.PublishLeaseGrantBox(context.Background(), boxID2, boxKey2, req2.RequestId); err != nil {
		t.Fatal(err)
	}
	endPayload2, _ := proto.Marshal(&pb.EndRequest{Domain: keyring.EndDomain, RequestId: req2.RequestId, DeviceKeyId: watchDev.KeyId, EndedUnixSeconds: time.Now().Unix()})
	signedEnd2, _ := keyring.SignKeyringDocument(endPayload2, watchDev.ReplyKeyId, keyring.NewSoftwarePayloadSigner(watchReply))
	endRaw2, _ := proto.Marshal(signedEnd2)
	if stopped, err := relay.StopLeaseGrantBox(context.Background(), boxID2, boxKey2, req2.RequestId, endRaw2); err != nil || !stopped {
		t.Fatalf("Stop 2: stopped=%v err=%v", stopped, err)
	}
	if err := client.checkStopInBox(context.Background(), req2.RequestId, req2); err == nil {
		t.Fatal("checkStopInBox accepted Stop from recently-removed Watch")
	}
}

func storeApprovedRequest(t *testing.T, client *RemoteKeyringClient, req *pb.Request) {
	t.Helper()
	signedReq, err := keyring.SignRequest(req, client.signRemoteLeasePayload)
	if err != nil {
		t.Fatal(err)
	}
	signedReqRaw, _ := proto.Marshal(signedReq)
	err = client.Store.UpdateClientState(context.Background(), func(st *clientstate.State) error {
		st.Requests = []*clientstate.ExpectedRequest{{
			LeaseId:  req.RequestId,
			Request:  signedReqRaw,
			GrantPut: true,
			Lease: &pb.Lease{
				RequestId:           req.RequestId,
				LoginId:             "login-1",
				State:               pb.LeaseState_LEASE_STATE_APPROVED,
				AnswerByUnixSeconds: req.AnswerByUnixSeconds,
				NotAfterUnixSeconds: time.Now().Add(30 * time.Minute).Unix(),
			},
		}}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestTakeBoxAnswerDistinguishesRefusedFromStoreError(t *testing.T) {
	srv := startTestRelayBoxServer(t)
	client, _, _, _, _, _, _, _ := testNewClientFixture(t, srv.URL)
	rogueSign, _, rogueDev := testDevice(t, "Rogue")
	rogueDev.Kind = pb.DeviceKind_DEVICE_KIND_WATCH

	boxID, boxKey := box.GenerateBoxID()
	req := &pb.Request{
		Domain:              keyring.RequestDomain,
		RequestId:           "req-ans-1",
		LoginId:             "login-1",
		MachineId:           func() string { s, _ := tlsid.ExtractCertificateSPKI(client.Certificate); return keyring.DeriveKeyID(s) }(),
		AskedUnixSeconds:    time.Now().Unix(),
		AnswerByUnixSeconds: time.Now().Add(10 * time.Minute).Unix(),
		AnswerBoxId:         boxID,
		AnswerBoxKey:        boxKey,
		AnswerBoxUrl:        srv.URL,
	}
	signedReq, _ := keyring.SignRequest(req, client.signRemoteLeasePayload)
	signedReqRaw, _ := proto.Marshal(signedReq)
	savedReq := &clientstate.ExpectedRequest{
		Scope:   &pb.RequestLeaseRequest{LoginId: "login-1", RequestId: "client-req-1"},
		LeaseId: req.RequestId,
		Request: signedReqRaw,
		Lease: &pb.Lease{
			RequestId:           req.RequestId,
			LoginId:             "login-1",
			State:               pb.LeaseState_LEASE_STATE_WAITING,
			AnswerByUnixSeconds: req.AnswerByUnixSeconds,
		},
	}
	if err := client.Store.UpdateClientState(context.Background(), func(st *clientstate.State) error {
		st.Requests = []*clientstate.ExpectedRequest{savedReq}
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	// 1. Refused answer (from unknown device) must delete the box entry and keep request WAITING.
	upload, err := keyring.BuildSignedApproval(signedReq.Payload, &pb.LoginSecret{LoginId: "login-1", Username: "u", Password: "p"},
		[]string{"https://example.com"}, client.receiving.PublicKey().Bytes(), rogueDev.KeyId, keyring.NewSoftwarePayloadSigner(rogueSign), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	rawUpload, _ := proto.Marshal(upload)
	relay := box.NewRelayBoxClient(srv.URL)
	if err := relay.PutRelayBox(context.Background(), boxID, boxKey, rawUpload, box.RelayBoxPutOptions{}); err != nil {
		t.Fatal(err)
	}
	if moved := client.takeBoxAnswer(context.Background(), savedReq, req); moved {
		t.Fatal("refused answer must not mark request moved")
	}
	if answer, err := relay.FetchRelayBox(t.Context(), boxID, boxKey, ""); err != nil || answer != nil {
		t.Fatalf("fetch after refusing the answer: found=%t err=%v, want no box", answer != nil, err)
	}
	st, _ := client.Store.LoadClientState(context.Background())
	if got := findSavedLeaseRequest(st, req.RequestId).Lease.State; got != pb.LeaseState_LEASE_STATE_WAITING {
		t.Fatalf("after refused answer, state = %v, want WAITING", got)
	}

	checkBoxAnswerStoreFailure(t, client, req, savedReq, relay)
}

func checkBoxAnswerStoreFailure(t *testing.T, client *RemoteKeyringClient, req *pb.Request, savedReq *clientstate.ExpectedRequest, relay *box.RelayBoxClient) {
	t.Helper()
	// A local store failure must leave the answer available for retry.
	boxID, boxKey := req.AnswerBoxId, req.AnswerBoxKey
	plainDenyRaw, _ := proto.Marshal(&pb.AnswerUpload{DenyRequestId: req.RequestId})
	if err := relay.PutRelayBox(context.Background(), boxID, boxKey, plainDenyRaw, box.RelayBoxPutOptions{}); err != nil {
		t.Fatal(err)
	}
	// Occupy the lock path with a directory so the store cannot open its lock file.
	lockPath := filepath.Join(client.Store.Directory, "state.lock")
	if err := os.Remove(lockPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(lockPath, 0o700); err != nil {
		t.Fatal(err)
	}

	if moved := client.takeBoxAnswer(context.Background(), savedReq, req); moved {
		t.Fatal("transient store error must not mark request moved")
	}
	answer, err := relay.FetchRelayBox(t.Context(), boxID, boxKey, "")
	if err != nil || answer == nil || !bytes.Equal(answer.Message, plainDenyRaw) {
		t.Fatalf("the relay did not retain the denial after a store error: found=%t err=%v", answer != nil, err)
	}
	if err := os.Remove(lockPath); err != nil {
		t.Fatal(err)
	}
	st, err := client.Store.LoadClientState(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if got := findSavedLeaseRequest(st, req.RequestId).Lease.State; got != pb.LeaseState_LEASE_STATE_WAITING {
		t.Fatalf("after store error, state = %v, want WAITING", got)
	}
}

func TestAskRemovesUnsentRequestOnInitialPushFailure(t *testing.T) {
	srv := startTestRelayBoxServer(t)
	client, macSign, _, _, _, phoneReply, phoneDev, _ := testNewClientFixture(t, srv.URL)

	// Add a valid phone registration so canPush passes, then point APNs relay at a dead port.
	phoneNoticeKey, _ := ecdh.P256().GenerateKey(rand.Reader)
	regPhone := testSign(t, phoneReply, &pb.PushRegistration{
		Domain: keyring.PushDomain, DeviceKeyId: phoneDev.KeyId, ApnsToken: []byte("11111111111111111111111111111111"),
		ApnsTopic: "com.example.phone", NoticePublicKey: phoneNoticeKey.PublicKey().Bytes(), RegisteredUnixSeconds: 100,
	})
	cat := testSign(t, macSign, &pb.Catalogue{
		Domain:   keyring.CatalogueDomain,
		Revision: 1,
		Logins:   []*pb.Login{{LoginId: "login-1", Title: "Example", Rule: pb.Rule_RULE_ASK, Version: 1}},
	})
	if err := client.Store.UpdateClientState(context.Background(), func(st *clientstate.State) error {
		st.Bundle, _ = proto.Marshal(&pb.Bundle{Catalogue: cat, PushRegistrations: []*pb.Signed{regPhone}})
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	deadRelay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	deadURL := deadRelay.URL
	deadRelay.Close()
	t.Setenv("AGENT_KEYRING_PUSH_RELAY_URL", deadURL)

	scope := &pb.RequestLeaseRequest{LoginId: "login-1", TaskRef: "t1", Reason: "Need login", RequestId: "retry-id-1"}
	if _, err := client.requestRemoteLease(context.Background(), scope); err == nil {
		t.Fatal("expected ask to fail when initial push fails")
	}
	st, err := client.Store.LoadClientState(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.Requests) != 0 {
		t.Fatalf("unsent request was kept in state.Requests (%d entries)", len(st.Requests))
	}

	// Retry with the exact same RequestId once APNs relay is reachable: must not be poisoned by CANCELLED.
	okRelay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer okRelay.Close()
	t.Setenv("AGENT_KEYRING_PUSH_RELAY_URL", okRelay.URL)

	lease, err := client.requestRemoteLease(context.Background(), scope)
	if err != nil {
		t.Fatalf("expected retry to succeed, got err=%v", err)
	}
	if lease == nil || lease.State != pb.LeaseState_LEASE_STATE_WAITING {
		t.Fatalf("expected PENDING lease after retry, got %+v", lease)
	}
	st, _ = client.Store.LoadClientState(context.Background())
	if len(st.Requests) != 1 || st.Requests[0].Lease.State != pb.LeaseState_LEASE_STATE_WAITING {
		t.Fatalf("expected 1 WAITING request after retry, got %+v", st.Requests)
	}

}

func TestSettleDuePrunesOldTerminalRequests(t *testing.T) {
	srv := startTestRelayBoxServer(t)
	client, _, _, _, _, _, _, _ := testNewClientFixture(t, srv.URL)
	// Verify settleDue prunes terminal requests older than 24h while keeping recent and active ones.
	now := time.Now().Unix()
	err := client.Store.UpdateClientState(context.Background(), func(st *clientstate.State) error {
		st.Requests = []*clientstate.ExpectedRequest{
			{
				LeaseId: "old-denied",
				Scope:   &pb.RequestLeaseRequest{RequestId: "r-old-denied"},
				Lease:   &pb.Lease{RequestId: "old-denied", State: pb.LeaseState_LEASE_STATE_DENIED, AnswerByUnixSeconds: now - 90000},
			},
			{
				LeaseId: "old-ended",
				Scope:   &pb.RequestLeaseRequest{RequestId: "r-old-ended"},
				Lease:   &pb.Lease{RequestId: "old-ended", State: pb.LeaseState_LEASE_STATE_ENDED, AnswerByUnixSeconds: now - 90000, NotAfterUnixSeconds: now - 88000},
			},
			{
				LeaseId: "recent-cancelled",
				Scope:   &pb.RequestLeaseRequest{RequestId: "r-recent-cancelled"},
				Lease:   &pb.Lease{RequestId: "recent-cancelled", State: pb.LeaseState_LEASE_STATE_CANCELLED, AnswerByUnixSeconds: now - 3600},
			},
			{
				LeaseId: "active-approved",
				Scope:   &pb.RequestLeaseRequest{RequestId: "r-active"},
				Lease:   &pb.Lease{RequestId: "active-approved", State: pb.LeaseState_LEASE_STATE_APPROVED, AnswerByUnixSeconds: now - 90000, NotAfterUnixSeconds: now + 600},
			},
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	client.settleDue(context.Background())
	st, _ := client.Store.LoadClientState(context.Background())
	if findSavedLeaseRequest(st, "old-denied") != nil || findSavedLeaseRequest(st, "old-ended") != nil {
		t.Fatalf("old terminal requests were not pruned: %+v", st.Requests)
	}
	if findSavedLeaseRequest(st, "recent-cancelled") == nil || findSavedLeaseRequest(st, "active-approved") == nil {
		t.Fatalf("recent or active requests were pruned: %+v", st.Requests)
	}
}

func TestReadMailboxReadsNewlyDiscoveredDeviceSlotsInSamePass(t *testing.T) {
	srv := startTestRelayBoxServer(t)
	client, macSign, _, macDev, phoneSign, _, phoneDev, seed := testNewClientFixture(t, srv.URL)

	// Start with only Mac in Members rev 1.
	members1 := &pb.Members{
		Domain:   keyring.MembersDomain,
		Revision: 1,
		Devices:  []*pb.Device{macDev},
		Machines: []*pb.Machine{{MachineId: func() string { s, _ := tlsid.ExtractCertificateSPKI(client.Certificate); return keyring.DeriveKeyID(s) }(), Label: "Linux"}},
	}
	if err := client.Store.UpdateClientState(context.Background(), func(st *clientstate.State) error {
		st.Members, _ = proto.Marshal(testSign(t, macSign, members1))
		return nil
	}); err != nil {
		t.Fatal(err)
	}

	// Mac's slot advances Members to rev 2 (adding iPhone).
	members2 := &pb.Members{
		Domain:   keyring.MembersDomain,
		Revision: 2,
		Devices:  []*pb.Device{macDev, phoneDev},
		Machines: members1.Machines,
	}
	macBundleRaw, _ := proto.Marshal(&pb.Bundle{Members: testSign(t, macSign, members2)})

	// iPhone's slot carries Catalogue rev 2 signed by iPhone!
	cat2 := &pb.Catalogue{
		Domain:   keyring.CatalogueDomain,
		Revision: 2,
		Logins:   []*pb.Login{{LoginId: "login-from-phone", Title: "From iPhone", Rule: pb.Rule_RULE_ASK, Version: 2}},
	}
	phoneBundleRaw, _ := proto.Marshal(&pb.Bundle{Catalogue: testSign(t, phoneSign, cat2)})

	st, _ := client.Store.LoadClientState(context.Background())
	relay := box.NewRelayBoxClient(srv.URL)
	mailboxPut := box.RelayBoxPutOptions{
		TTL: box.TTLUpdate, Mode: box.ModeReplace, ReadAuth: st.Mailbox.ReadAuth, WriteAuth: box.GenerateBoxAuthToken(),
	}
	if err := relay.PutRelayBox(context.Background(), box.DeriveUpdateMailboxSlot(seed, macDev.KeyId), box.DeriveUpdateMailboxKey(seed), macBundleRaw,
		mailboxPut); err != nil {
		t.Fatal(err)
	}
	if err := relay.PutRelayBox(context.Background(), box.DeriveUpdateMailboxSlot(seed, phoneDev.KeyId), box.DeriveUpdateMailboxKey(seed), phoneBundleRaw,
		mailboxPut); err != nil {
		t.Fatal(err)
	}

	v, err := client.refreshRemoteCatalogue(context.Background())
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if v.findCatalogueLogin("login-from-phone") == nil {
		t.Fatalf("new device iPhone slot was not read in the same refresh pass; catalogue logins=%+v", v.catalogue.GetLogins())
	}
}
