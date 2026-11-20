// Written by AI on 2026.11.19 by model claude opus 5.5.
package relay

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/apns"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"github.com/joshp123/agent-keyring/internal/tlsid"
	"google.golang.org/protobuf/proto"
)

// Another computer that claims to have answered its own request as the Mac
// would must not be shown as approved on the iPhone; only the Mac may.
func TestOnlyTheMacAnswersItsOwnRequest(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store}
	linux := &pb.Machine{MachineId: "linux", Label: "Linux server"}
	mac := &pb.Machine{MachineId: "mac", Label: "MacBook Pro"}
	macDevice := &pb.Device{KeyId: "mac-device", Kind: pb.DeviceKind_DEVICE_KIND_MAC, Label: "MacBook Pro"}
	store.update(func(data *saved) error {
		data.Requests["from-linux"] = &request{MachineID: "linux", State: pb.LeaseState_LEASE_STATE_WAITING}
		data.Requests["from-mac"] = &request{MachineID: "mac", State: pb.LeaseState_LEASE_STATE_WAITING}
		return nil
	})
	lease, err := s.end(context.Background(), caller{machine: linux}, "from-linux", "approved")
	if err != nil || lease.State != pb.LeaseState_LEASE_STATE_CANCELLED || lease.AnsweredBy != "" {
		t.Fatalf("another computer marked its own request approved: %v %v", lease, err)
	}
	lease, err = s.end(context.Background(), caller{machine: mac, device: macDevice}, "from-mac", "approved")
	if err != nil || lease.State != pb.LeaseState_LEASE_STATE_APPROVED || lease.AnsweredBy != "MacBook Pro" {
		t.Fatalf("the Mac's own answer was not recorded: %v %v", lease, err)
	}
}

// Josh sets a login to Blocked: every copy of it leaves the relay, and the
// Mac's next export does not put one back while it stays Blocked.
func TestABlockedLoginHasNoCopyOnTheRelay(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	mac := &pb.Device{KeyId: "mac", Kind: pb.DeviceKind_DEVICE_KIND_MAC, SigningPublicKey: elliptic.Marshal(elliptic.P256(), key.X, key.Y)}
	iphone := &pb.Device{KeyId: "iphone", Kind: pb.DeviceKind_DEVICE_KIND_IPHONE}
	store.members = &pb.Members{Devices: []*pb.Device{mac, iphone}, Machines: []*pb.Machine{{MachineId: "mini"}}}
	publish := func(revision uint64, rule pb.Rule) {
		t.Helper()
		payload, _ := proto.Marshal(&pb.Catalogue{Domain: keyring.CatalogueDomain, Revision: revision,
			Logins: []*pb.Login{{LoginId: "shop", Rule: rule}, {LoginId: "mail", Rule: pb.Rule_RULE_ASK}}})
		signed, _ := keyring.Sign(payload, "mac", keyring.SoftwareSigner(key))
		if err := s.publishCatalogue(signed); err != nil {
			t.Fatal(err)
		}
	}
	export := func() {
		t.Helper()
		batch := &pb.SealedLogins{Logins: []*pb.SealedLogin{
			{LoginId: "shop", OpenerId: "iphone"}, {LoginId: "shop", OpenerId: "mini"}, {LoginId: "mail", OpenerId: "iphone"}}}
		if err := s.publishSealedLogins(batch); err != nil {
			t.Fatal(err)
		}
	}
	held := func(opener string) []string {
		var ids []string
		for _, sealed := range s.sealedFor(opener).Logins {
			ids = append(ids, sealed.LoginId)
		}
		return ids
	}
	publish(1, pb.Rule_RULE_AUTOMATIC)
	export()
	if len(held("iphone")) != 2 || len(held("mini")) != 1 {
		t.Fatalf("before blocking: iPhone holds %v, mini holds %v", held("iphone"), held("mini"))
	}
	publish(2, pb.Rule_RULE_BLOCKED)
	if !slices.Equal(held("iphone"), []string{"mail"}) || len(held("mini")) != 0 {
		t.Fatalf("after blocking: iPhone holds %v, mini holds %v", held("iphone"), held("mini"))
	}
	export()
	if !slices.Equal(held("iphone"), []string{"mail"}) || len(held("mini")) != 0 {
		t.Fatalf("a later export put a Blocked login back: iPhone holds %v, mini holds %v", held("iphone"), held("mini"))
	}
	// His own copy replaces the sample password: a login no longer listed keeps no copy.
	payload, _ := proto.Marshal(&pb.Catalogue{Domain: keyring.CatalogueDomain, Revision: 3, Logins: []*pb.Login{{LoginId: "shop", Rule: pb.Rule_RULE_ASK}}})
	signed, _ := keyring.Sign(payload, "mac", keyring.SoftwareSigner(key))
	if err := s.publishCatalogue(signed); err != nil {
		t.Fatal(err)
	}
	if len(held("iphone")) != 0 {
		t.Fatalf("a login no longer listed kept its copies: iPhone holds %v", held("iphone"))
	}
}

// A request at every size limit the relay allows, signed, with a sealed copy
// and its login, still fits in the 4096 bytes Apple carries.
func TestTheLargestRequestFitsInAPush(t *testing.T) {
	long := func(n int) string { return strings.Repeat("x", n) }
	machineKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	request, _ := keyring.SignRequest(&pb.Request{Domain: keyring.RequestDomain, RequestId: long(32), LoginId: long(36), MachineId: long(64),
		Reason: long(400), Agent: long(100), Project: long(100), Task: long(100), AskedUnixSeconds: 1 << 40, AnswerByUnixSeconds: 1 << 40},
		keyring.SoftwareSigner(machineKey))
	opening, _ := ecdh.P256().GenerateKey(rand.Reader)
	sealed, _ := keyring.SealLogin(&pb.LoginSecret{LoginId: long(36), Username: long(100), Password: long(128), TotpSeed: make([]byte, 64),
		Title: long(100), Sites: []string{long(100), long(100)}}, 1<<62, opening.PublicKey().Bytes(), long(64), long(64), keyring.SoftwareSigner(machineKey))
	work := &pb.Work{Request: request.Payload, RequestSignature: request.Signature, SealedLogin: sealed,
		Login: &pb.Login{LoginId: long(36), Title: long(100), Sites: []string{long(100), long(100)}, Account: long(100), Rule: pb.Rule_RULE_ASK, Version: 1 << 62}}
	notice, _ := ecdh.P256().GenerateKey(rand.Reader)
	sealedNotice, err := keyring.SealNotice(work, notice.PublicKey().Bytes(), long(64))
	if err != nil {
		t.Fatal(err)
	}
	if size := len(pushPayload(long(32), sealedNotice, true)); size > 4096 {
		t.Fatalf("the push is %d bytes; Apple carries 4096", size)
	} else {
		t.Logf("largest push: %d bytes", size)
	}
}

// After the Apple Watch joins, its iPhone asks for a practice request for it;
// only the Watch can answer it. The Mac or the iPhone may ask for one for any
// device; the Watch asks only for its own.
func TestTheAppleWatchGetsItsOwnPracticeRequest(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store}
	watchKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	watchPublic := elliptic.Marshal(elliptic.P256(), watchKey.X, watchKey.Y)
	iphone := &pb.Device{KeyId: "iphone", Kind: pb.DeviceKind_DEVICE_KIND_IPHONE, Label: "iPhone"}
	mac := &pb.Device{KeyId: "mac", Kind: pb.DeviceKind_DEVICE_KIND_MAC, Label: "MacBook Pro"}
	watch := &pb.Device{KeyId: keyring.KeyID(watchPublic), Kind: pb.DeviceKind_DEVICE_KIND_WATCH, Label: "Apple Watch", SigningPublicKey: watchPublic}
	store.members = &pb.Members{Devices: []*pb.Device{iphone, mac, watch}}
	ignore := func(*pb.RelayResponse) error { return nil }
	if err := s.testRequest(context.Background(), caller{device: watch}, &pb.TestRequest{ForDeviceKeyId: iphone.KeyId}, ignore); err == nil {
		t.Fatal("the Apple Watch asked for a practice request for the iPhone")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	outcome := make(chan *pb.Lease, 1)
	go s.testRequest(ctx, caller{device: iphone}, &pb.TestRequest{ForDeviceKeyId: watch.KeyId}, func(response *pb.RelayResponse) error {
		if lease := response.GetLease(); lease.GetState() != pb.LeaseState_LEASE_STATE_WAITING {
			outcome <- lease
		}
		return nil
	})
	var work *pb.Work
	for deadline := time.Now().Add(5 * time.Second); work == nil && time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		store.read(func(data *saved) {
			for id, r := range data.Requests {
				if r.ForDevice == watch.KeyId {
					work, _ = s.work(watch, id, data)
				}
			}
		})
	}
	if work == nil {
		t.Fatal("no practice request for the Apple Watch")
	}
	now := time.Now()
	payload, _ := proto.Marshal(&pb.Answer{Domain: keyring.AnswerDomain, RequestSha256: keyring.SHA256(work.Request), Choice: pb.Choice_CHOICE_APPROVE,
		DecidedUnixSeconds: now.Unix(), NotAfterUnixSeconds: now.Unix() + 60})
	byIPhone, _ := keyring.Sign(payload, "iphone", keyring.SoftwareSigner(watchKey))
	if _, err := s.answer(ctx, caller{device: iphone}, &pb.AnswerUpload{Answer: byIPhone}); err == nil {
		t.Fatal("another device answered the Apple Watch's practice request")
	}
	signed, _ := keyring.Sign(payload, watch.KeyId, keyring.SoftwareSigner(watchKey))
	if _, err := s.answer(ctx, caller{device: watch}, &pb.AnswerUpload{Answer: signed}); err != nil {
		t.Fatalf("the Apple Watch's answer: %v", err)
	}
	if lease := <-outcome; lease.State != pb.LeaseState_LEASE_STATE_APPROVED {
		t.Fatalf("the iPhone saw %v", lease.State)
	}
}

// Josh denies a request on his iPhone: the request arrived as a notification
// he sees and hears, and its outcome comes as a silent push, so his Apple Watch
// and iPhone take the notification away instead of showing another.
func TestOnlyANewRequestIsANotificationHeSees(t *testing.T) {
	type push struct {
		kind string
		aps  map[string]any
		id   string
	}
	pushes := make(chan push, 4)
	gateway := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Aps map[string]any `json:"aps"`
			ID  string         `json:"id"`
		}
		json.NewDecoder(r.Body).Decode(&body)
		pushes <- push{r.Header.Get("apns-push-type"), body.Aps, body.ID}
	}))
	gateway.EnableHTTP2 = true
	gateway.StartTLS()
	defer gateway.Close()
	dir := t.TempDir()
	ca := filepath.Join(dir, "ca.pem")
	os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: gateway.Certificate().Raw}), 0o600)
	signing, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, _ := x509.MarshalPKCS8PrivateKey(signing)
	keyPath := filepath.Join(dir, "key.p8")
	os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600)
	sender, err := apns.New(apns.Config{KeyPath: keyPath, KeyID: "KEY", TeamID: "TEAM", TestGateway: gateway.URL, TestCA: ca})
	if err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store, Push: sender}
	iphone := &pb.Device{KeyId: "iphone", Kind: pb.DeviceKind_DEVICE_KIND_IPHONE, Label: "iPhone"}
	store.members = &pb.Members{Devices: []*pb.Device{iphone}}
	notice, _ := ecdh.P256().GenerateKey(rand.Reader)
	store.update(func(data *saved) error {
		data.Pushes["iphone"] = marshal(&pb.PushRegistration{DeviceKeyId: "iphone", ApnsToken: []byte{1, 2, 3}, ApnsTopic: "com.example.Phone",
			NoticePublicKey: notice.PublicKey().Bytes()})
		return nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go s.testRequest(ctx, caller{device: iphone}, &pb.TestRequest{}, func(*pb.RelayResponse) error { return nil })
	arrived := <-pushes
	if arrived.kind != "alert" || arrived.aps["alert"] == nil || arrived.aps["sound"] != "default" {
		t.Fatalf("the new request was not a notification he sees and hears: %v", arrived)
	}
	var id string
	store.read(func(data *saved) {
		for key := range data.Requests {
			id = key
		}
	})
	if _, err := s.answer(ctx, caller{device: iphone}, &pb.AnswerUpload{DenyRequestId: id}); err != nil {
		t.Fatal(err)
	}
	outcome := <-pushes
	if outcome.kind != "background" || outcome.aps["alert"] != nil || outcome.aps["sound"] != nil || outcome.aps["content-available"] != float64(1) || outcome.id != id {
		t.Fatalf("the outcome was not a silent push: %v", outcome)
	}
}

// Josh denies an agent with a word of explanation: it may ask again a minute
// later and is told when and what he said; a second denial in a row holds it
// five minutes; an approval starts again at a minute. A device removed a moment
// ago can no longer answer.
func TestADenialHoldsBrieflyAndLongerEachTimeInARow(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 20, 1, 0, 0, 0, time.Local)
	s := &Server{Store: store, Now: func() time.Time { return now }}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	iphone := &pb.Device{KeyId: "iphone", Kind: pb.DeviceKind_DEVICE_KIND_IPHONE, Label: "iPhone",
		SigningPublicKey: elliptic.Marshal(elliptic.P256(), key.X, key.Y)}
	store.members = &pb.Members{Devices: []*pb.Device{iphone}, Machines: []*pb.Machine{{MachineId: "mini"}}}
	store.catalogue = &pb.Catalogue{Logins: []*pb.Login{{LoginId: "bank", Rule: pb.Rule_RULE_ASK}}}
	answer := func(id string, choice pb.Choice, reply string) *pb.Lease {
		t.Helper()
		asked := marshal(&pb.Request{LoginId: "bank", RequestId: id})
		store.update(func(data *saved) error {
			data.Requests[id] = &request{Request: asked, MachineID: "mini", State: pb.LeaseState_LEASE_STATE_WAITING, AnswerBy: now.Unix() + 600}
			return nil
		})
		delivery := &pb.Delivery{Ciphertext: []byte("sealed for the asking computer")}
		payload := marshal(&pb.Answer{Domain: keyring.AnswerDomain, RequestSha256: keyring.SHA256(asked), Choice: choice, Reply: reply,
			DecidedUnixSeconds: now.Unix(), NotAfterUnixSeconds: now.Unix() + 600, DeliverySha256: keyring.SHA256(delivery.Ciphertext)})
		signed, _ := keyring.Sign(payload, "iphone", keyring.SoftwareSigner(key))
		lease, err := s.answer(context.Background(), caller{device: iphone}, &pb.AnswerUpload{Answer: signed, Delivery: delivery})
		if err != nil {
			t.Fatalf("answer %s: %v", id, err)
		}
		return lease
	}
	held := func() *hold {
		var h *hold
		store.read(func(data *saved) { h = data.Holds[heldOffKey("mini", "bank")] })
		return h
	}
	answer("first", pb.Choice_CHOICE_DENY, "Use the work account.")
	if h := held(); h.Until != now.Add(time.Minute).Unix() {
		t.Fatalf("the first denial held it until %v", time.Unix(h.Until, 0))
	}
	if message := heldOffMessage(held(), now); !strings.Contains(message, "in 1m0s") || !strings.Contains(message, "\"Use the work account.\"") {
		t.Fatalf("the agent was not told when, or his words: %s", message)
	}
	now = now.Add(2 * time.Minute)
	answer("second", pb.Choice_CHOICE_DENY, "")
	if h := held(); h.Until != now.Add(5*time.Minute).Unix() || h.InARow != 2 {
		t.Fatalf("a second denial in a row held it until %v (%d in a row)", time.Unix(h.Until, 0), h.InARow)
	}
	now = now.Add(6 * time.Minute)
	if lease := answer("approved", pb.Choice_CHOICE_APPROVE, ""); lease.State != pb.LeaseState_LEASE_STATE_APPROVED || held() != nil {
		t.Fatalf("the approval did not start the hold again: %v %v", lease, held())
	}
	answer("third", pb.Choice_CHOICE_DENY, "")
	if h := held(); h.Until != now.Add(time.Minute).Unix() {
		t.Fatalf("after an approval a denial held it until %v", time.Unix(h.Until, 0))
	}
	store.members = &pb.Members{Machines: []*pb.Machine{{MachineId: "mini"}}}
	store.update(func(data *saved) error {
		data.Requests["after-removal"] = &request{MachineID: "mini", State: pb.LeaseState_LEASE_STATE_WAITING, AnswerBy: now.Unix() + 600}
		return nil
	})
	if _, err := s.answer(context.Background(), caller{device: iphone}, &pb.AnswerUpload{DenyRequestId: "after-removal"}); err == nil {
		t.Fatal("a device removed from the members list still answered")
	}
}

// Josh adds his Apple Watch on the iPhone while the Mac is connected: the Mac
// hears at once that the members list changed, on the connection it already
// has, so a request it sent is answerable from the Watch. The Mac also hears
// who is waiting to join without asking every few seconds.
func TestTheMacHearsOfANewDeviceWithoutAsking(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store}
	mac := &pb.Device{KeyId: "mac", Kind: pb.DeviceKind_DEVICE_KIND_MAC}
	store.members = &pb.Members{Revision: 3, Devices: []*pb.Device{mac}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	changes := make(chan *pb.Changes, 8)
	go s.watchWork(ctx, caller{device: mac}, func(response *pb.RelayResponse) error {
		if c := response.GetChanges(); c != nil {
			changes <- c
		}
		return nil
	})
	next := func() *pb.Changes {
		t.Helper()
		select {
		case c := <-changes:
			return c
		case <-time.After(5 * time.Second):
			t.Fatal("the Mac heard nothing")
			return nil
		}
	}
	if c := next(); c.MembersRevision != 3 {
		t.Fatalf("the stream opened with revision %d", c.MembersRevision)
	}
	store.update(func(data *saved) error {
		store.members = &pb.Members{Revision: 4, Devices: []*pb.Device{mac, {KeyId: "watch", Kind: pb.DeviceKind_DEVICE_KIND_WATCH}}}
		data.Joins["linux"] = &join{Request: marshal(&pb.JoinRequest{}), State: pb.JoinState_JOIN_STATE_WAITING, Node: "linux"}
		return nil
	})
	if c := next(); c.MembersRevision != 4 || len(c.PendingJoins) != 1 {
		t.Fatalf("after the Apple Watch joined the Mac heard %v", c)
	}
}

// An agent finds out what happened to a request from any computer: the
// relay's own lines and each device's latest log, merged in time order and
// cut to that request. A log signed by another device is refused.
func TestOneCommandGathersWhatHappenedToARequest(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ring := &Ring{}
	s := &Server{Store: store, Ring: ring}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(elliptic.P256(), key.X, key.Y)
	iphone := &pb.Device{KeyId: "iphone", Kind: pb.DeviceKind_DEVICE_KIND_IPHONE, ReplyKeyId: "iphone-reply", ReplyPublicKey: public}
	store.members = &pb.Members{Devices: []*pb.Device{iphone}}
	logger := slog.New(ring.Handler(slog.NewTextHandler(io.Discard, nil)))
	logger.Info("request", "id", "abc123", "machine", "Mac mini")
	payload := marshal(&pb.DeviceLog{Domain: keyring.LogDomain, DeviceKeyId: iphone.KeyId, Lines: []string{
		"2000-01-01T00:00:00.000Z iphone answer sent request=abc123 choice=approve via=app",
		"2000-01-01T00:00:01.000Z iphone app front",
	}})
	signed, _ := keyring.Sign(payload, iphone.ReplyKeyId, keyring.SoftwareSigner(key))
	if err := s.reportLog(signed); err != nil {
		t.Fatal(err)
	}
	forged, _ := keyring.Sign(marshal(&pb.DeviceLog{Domain: keyring.LogDomain, DeviceKeyId: "watch"}), iphone.ReplyKeyId, keyring.SoftwareSigner(key))
	if err := s.reportLog(forged); err == nil {
		t.Fatal("a log naming another device was kept")
	}
	lines := s.logs(&pb.LogsRequest{RequestId: "abc123"}).Lines
	if len(lines) != 2 || !strings.Contains(lines[0], "iphone answer sent") || !strings.Contains(lines[1], " relay request id=abc123 machine=\"Mac mini\"") {
		t.Fatalf("gathered %q", lines)
	}
}

// Someone else on Josh's network reaches his new, empty relay before his Mac
// does: it refuses them. His Mac takes it with the secret the relay gave our
// app on its own computer, which only a caller there can get.
func TestOnlyTheRelaysOwnComputerCanHandOutAnEmptyRelay(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	certificate, key, _ := tlsid.New("relay")
	pair, _ := tls.X509KeyPair(certificate, key)
	s := &Server{Store: store, Certificate: pair}
	if _, err := s.setupOffer(caller{}); err == nil {
		t.Fatal("a caller on another computer got the setup offer")
	}
	offer, err := s.setupOffer(caller{local: true})
	if err != nil {
		t.Fatal(err)
	}
	signing, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(elliptic.P256(), signing.X, signing.Y)
	first := func(spki []byte, proof []byte) error {
		mac := &pb.Device{KeyId: keyring.KeyID(public), Kind: pb.DeviceKind_DEVICE_KIND_MAC, SigningPublicKey: public, TlsPublicKey: spki}
		payload := marshal(&pb.Members{Domain: keyring.MembersDomain, Revision: 1, Devices: []*pb.Device{mac},
			RelayTlsPublicKey: offer.RelayTlsPublicKey, SetupProof: proof})
		signed, _ := keyring.Sign(payload, mac.KeyId, keyring.SoftwareSigner(signing))
		return s.publishMembers(caller{spki: spki}, signed)
	}
	if err := first([]byte("stranger"), nil); err == nil {
		t.Fatal("a stranger took the empty relay")
	}
	if err := first([]byte("mac"), keyring.SetupProof(offer.Secret, offer.RelayTlsPublicKey, keyring.KeyID(public))); err != nil {
		t.Fatalf("the Mac with the offer's proof was refused: %v", err)
	}
}

// He leaves the iPhone app while its practice request waits, so iOS cuts the
// connection, and the app asks again: it gets the same request, never a second.
func TestAPracticeRequestIsRejoinedNotMadeAgain(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{Store: store}
	iphone := &pb.Device{KeyId: "iphone", Kind: pb.DeviceKind_DEVICE_KIND_IPHONE}
	store.members = &pb.Members{Devices: []*pb.Device{iphone}}
	ask := func(id string) string {
		ctx, cancel := context.WithCancel(context.Background())
		got := make(chan string, 1)
		go s.testRequest(ctx, caller{device: iphone}, &pb.TestRequest{RequestId: id}, func(r *pb.RelayResponse) error {
			got <- r.GetLease().GetRequestId()
			return nil
		})
		defer cancel() // The connection drops.
		return <-got
	}
	first := strings.Repeat("a", 32)
	if again := ask(first); again != first || ask(first) != first || ask(strings.Repeat("b", 32)) != first {
		t.Fatal("asking again made another practice request")
	}
	waiting := 0
	store.read(func(data *saved) { waiting = len(data.Requests) })
	if waiting != 1 {
		t.Fatalf("%d practice requests were made", waiting)
	}
	// The device says it arrived: the asker hears it while it still waits.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	heard := make(chan *pb.Lease, 4)
	go s.testRequest(ctx, caller{device: iphone}, &pb.TestRequest{RequestId: first}, func(r *pb.RelayResponse) error {
		heard <- r.GetLease()
		return nil
	})
	<-heard
	store.update(func(data *saved) error { data.Requests[first].Arrived = 1; return nil })
	if lease := <-heard; lease.ArrivedUnixSeconds != 1 || lease.State != pb.LeaseState_LEASE_STATE_WAITING {
		t.Fatalf("the asker did not hear the arrival: %v", lease)
	}
}
