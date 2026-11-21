// Written by AI on 2026.11.18 by model claude opus 5.5; the practice request and refusals on 2026.11.19;
// moved to the direct design (no relay) on 2026.11.21.
//
// Stand-ins for Josh's Mac, iPhone and Apple Watch, and for Apple's push
// service, with software keys where the devices have their chips, for
// end-to-end tests of the command (proto/agentkeyring/v2/keyring.proto,
// "Direct: no relay"). They speak the same protocol as the apps, with
// made-up passwords and a made-up P-256 push key only: nothing here ever
// reaches Apple or a real device.
//
//	test-device init    --state DIR --door IP:PORT        the Mac, iPhone and Apple Watch: keys, lists, copies, push addresses
//	test-device mac     --state DIR [--join-within 10m]   serve the Mac's door until killed
//	test-device apple   --state DIR --listen IP:PORT      stand in for Apple until killed; writes DIR/apple-ca.pem
//	test-device invite  --state DIR [--host HOST]         print a one-time link for one computer to join
//	test-device approve-joins --state DIR                 approve every waiting computer, Automatic allowed
//	test-device refuse-joins  --state DIR [--reply WORDS] refuse every waiting computer
//	test-device answer  --state DIR --device iphone|watch [--request ID] (--approve | --deny WORDS | --deny-plain | --ignore)
//	                                                      answer the next request pushed to that device, at its door
//	test-device outcome --state DIR --device iphone|watch --request ID
//	                                                      wait for the silent push with that request's outcome
//	test-device stop    --state DIR --device iphone|watch --request ID
//	                                                      end an approval early, as Stop on a device does
//	                                                      (--door-retry 1s: give up on the door sooner; it is then left at the Mac)
//	test-device remove  --state DIR --device watch        Josh removes a device from his list
//	test-device mac-answer  --state DIR [--request ID] (--approve | --deny WORDS)
//	                                                      answer another computer's request shown on the Mac, at its door
//	test-device mac-outcome --state DIR --request ID      wait for the computer to tell the Mac how its request ended
package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"github.com/joshp123/agent-keyring/internal/tlsid"
	"google.golang.org/protobuf/proto"
)

// The made-up passwords. "login-ask" and "login-other" ask; "login-automatic" is Automatic.
var logins = []*pb.LoginSecret{
	{LoginId: "login-ask", Username: "agent@example.com", Password: "example-ask-password", TotpSeed: []byte("12345678901234567890")},
	{LoginId: "login-other", Username: "other@example.com", Password: "example-other-password"},
	{LoginId: "login-automatic", Username: "agent@automatic.example", Password: "example-automatic-password"},
}

// When the made-up passwords were imported: every sealed copy carries it.
const importedAt = 1763500000000000000

var catalogueLogins = []*pb.Login{
	{LoginId: "login-ask", Title: "Example", Sites: []string{"https://example.com"}, Account: "agent@example.com", HasOneTimeCode: true, Rule: pb.Rule_RULE_ASK, Version: importedAt},
	{LoginId: "login-other", Title: "Other example", Sites: []string{"https://other.example"}, Account: "other@example.com", Rule: pb.Rule_RULE_ASK, Version: importedAt},
	{LoginId: "login-automatic", Title: "Automatic example", Sites: []string{"https://automatic.example"}, Account: "agent@automatic.example", Rule: pb.Rule_RULE_AUTOMATIC, Version: importedAt},
}

// keys is one device's software keys, standing in for its chip.
type keys struct {
	Signing []byte `json:"signing"`
	Reply   []byte `json:"reply"`
	Opening []byte `json:"opening"`
	Notice  []byte `json:"notice"`
	Token   []byte `json:"token"` // Its made-up push address.
}

type join struct {
	Request []byte       `json:"request"` // JoinRequest.
	Secret  []byte       `json:"secret"`  // The invitation it proves.
	Asked   int64        `json:"asked"`
	State   pb.JoinState `json:"state"`
	Refusal []byte       `json:"refusal,omitempty"`
}

// saved is everything the stand-ins keep, in DIR/devices.json, changed only
// under DIR/devices.lock, so the Mac's door and the other commands share it.
type saved struct {
	Door           string           `json:"door"`
	MacCertificate []byte           `json:"mac_certificate"`
	MacTLSKey      []byte           `json:"mac_tls_key"`
	Devices        map[string]*keys `json:"devices"` // "mac", "iphone", "watch".
	PushKey        []byte           `json:"push_key"` // PKCS#8: made up, never Apple's.
	Members        []byte           `json:"members"`  // Signed: the newest.
	MembersHistory [][]byte         `json:"members_history"` // Every revision, oldest first.
	Catalogue      []byte           `json:"catalogue"`
	Copies         [][]byte         `json:"copies"`        // SealedLogin.
	Registrations  [][]byte         `json:"registrations"` // Signed PushRegistration.
	Revisions      [3]uint64        `json:"revisions"`     // Members, catalogue, copies.
	Secrets        [][]byte         `json:"secrets"`       // Invitations not yet used.
	Joins          map[string]*join `json:"joins"`
	Complaints     [][]byte         `json:"complaints"` // Complaint, as computers sent them.
	// The iPhone's TLS identity, for the Mac's members' door (POST /v2/stop).
	PhoneCertificate []byte `json:"phone_certificate"`
	PhoneTLSKey      []byte `json:"phone_tls_key"`
	// Other computers' requests the Mac was shown (POST /v2/ask), by id: the
	// Signed Request; how each ended (POST /v2/outcome): the Lease; and which
	// ones the Mac has answered itself.
	Asks       map[string][]byte `json:"asks"`
	Outcomes   map[string][]byte `json:"outcomes"`
	MacAnswers map[string]bool   `json:"mac_answers"`
	// Stops devices left at the Mac (POST /v2/stop), by request id, kept an hour.
	Stops map[string]*keptStop `json:"stops"`
}

type keptStop struct {
	Signed []byte `json:"signed"` // Signed EndRequest.
	At     int64  `json:"at"`
}

const (
	pushKeyID = "KEY0000000"
	teamID    = "TEAM000000"
	topic     = "com.example.AgentKeyring"
)

var labels = map[string]string{"mac": "Test Mac", "iphone": "Test iPhone", "watch": "Test Apple Watch"}
var kinds = map[string]pb.DeviceKind{"mac": pb.DeviceKind_DEVICE_KIND_MAC, "iphone": pb.DeviceKind_DEVICE_KIND_IPHONE, "watch": pb.DeviceKind_DEVICE_KIND_WATCH}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: test-device init|mac|apple|invite|approve-joins|refuse-joins|answer|outcome|stop|remove|mac-answer|mac-outcome --state DIR ...")
		os.Exit(2)
	}
	flags := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	state := flags.String("state", "", "state directory")
	doorAddress := flags.String("door", "", "the Mac's door, IP:PORT (init)")
	listen := flags.String("listen", "", "IP:PORT (apple)")
	host := flags.String("host", "", "the Mac's door as the invitation names it (invite)")
	joinWithin := flags.Duration("join-within", 10*time.Minute, "how long a join stays open (mac)")
	device := flags.String("device", "", "iphone or watch")
	approve := flags.Bool("approve", false, "approve the next request")
	deny := flags.String("deny", "", "deny the next request with these words")
	denyPlain := flags.Bool("deny-plain", false, "deny the next request with no words")
	ignore := flags.Bool("ignore", false, "see the next request and leave it unanswered")
	reply := flags.String("reply", "", "words for the waiting agent (refuse-joins)")
	request := flags.String("request", "", "request id")
	flags.DurationVar(&doorRetry, "door-retry", doorRetry, "how long a post to a computer's door retries while nothing answers")
	flags.Parse(os.Args[2:])
	if *state == "" {
		fmt.Fprintln(os.Stderr, "test-device: --state is required")
		os.Exit(2)
	}
	d := &devices{dir: *state}
	ctx := context.Background()
	var err error
	switch os.Args[1] {
	case "init":
		err = d.initialise(*doorAddress)
	case "mac":
		err = d.serveMac(*joinWithin)
	case "apple":
		err = d.serveApple(*listen)
	case "invite":
		err = d.invite(*host)
	case "approve-joins":
		err = d.decideJoins(true, "")
	case "refuse-joins":
		err = d.decideJoins(false, *reply)
	case "answer":
		err = d.answer(ctx, *device, *request, *approve, *deny, *denyPlain, *ignore)
	case "outcome":
		err = d.outcome(*device, *request)
	case "stop":
		err = d.stop(ctx, *device, *request)
	case "mac-answer":
		err = d.macAnswer(ctx, *request, *approve, *deny)
	case "mac-outcome":
		err = d.macOutcome(*request)
	case "remove":
		err = d.remove(*device)
	default:
		err = errors.New("unknown command")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "test-device:", err)
		os.Exit(1)
	}
}

// ---- The saved state ----------------------------------------------------------

type devices struct{ dir string }

// change runs one change to the saved state under its lock.
func (d *devices) change(apply func(*saved) error) error {
	lock, err := os.OpenFile(filepath.Join(d.dir, "devices.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	s := &saved{Devices: map[string]*keys{}, Joins: map[string]*join{}, Asks: map[string][]byte{}, Outcomes: map[string][]byte{},
		MacAnswers: map[string]bool{}, Stops: map[string]*keptStop{}}
	path := filepath.Join(d.dir, "devices.json")
	if raw, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(raw, s); err != nil {
			return err
		}
	}
	if err := apply(s); err != nil {
		return err
	}
	raw, err := json.Marshal(s)
	if err != nil {
		return err
	}
	return os.WriteFile(path, raw, 0o600)
}

func (d *devices) read() (*saved, error) {
	var copied *saved
	err := d.change(func(s *saved) error { copied = s; return nil })
	return copied, err
}

func ecdsaKey(raw []byte) *ecdsa.PrivateKey {
	key, err := x509.ParseECPrivateKey(raw)
	if err != nil {
		panic(err)
	}
	return key
}

func publicBytes(key *ecdsa.PrivateKey) []byte {
	return elliptic.Marshal(elliptic.P256(), key.X, key.Y) //nolint:staticcheck // X9.63 uncompressed, as CryptoKit writes.
}

func ecdhKey(raw []byte) *ecdh.PrivateKey {
	key, err := ecdh.P256().NewPrivateKey(raw)
	if err != nil {
		panic(err)
	}
	return key
}

// device is one device as the list of devices describes it.
func (s *saved) device(name string) *pb.Device {
	k := s.Devices[name]
	signing, reply := ecdsaKey(k.Signing), ecdsaKey(k.Reply)
	d := &pb.Device{KeyId: keyring.KeyID(publicBytes(signing)), Kind: kinds[name], Label: labels[name], SigningPublicKey: publicBytes(signing),
		OpeningPublicKey: ecdhKey(k.Opening).PublicKey().Bytes(), ReplyKeyId: keyring.KeyID(publicBytes(reply)), ReplyPublicKey: publicBytes(reply)}
	switch name {
	case "mac":
		d.TlsPublicKey = s.macSPKI()
	case "iphone":
		spki, _ := tlsid.SPKI(s.phoneCertificate())
		d.TlsPublicKey = spki
	}
	return d
}

func (s *saved) phoneCertificate() tls.Certificate {
	certificate, err := tls.X509KeyPair(s.PhoneCertificate, s.PhoneTLSKey)
	if err != nil {
		panic(err)
	}
	return certificate
}

func (s *saved) macCertificate() tls.Certificate {
	certificate, err := tls.X509KeyPair(s.MacCertificate, s.MacTLSKey)
	if err != nil {
		panic(err)
	}
	return certificate
}

func (s *saved) macSPKI() []byte {
	spki, _ := tlsid.SPKI(s.macCertificate())
	return spki
}

func (s *saved) members() *pb.Members {
	signed, members := &pb.Signed{}, &pb.Members{}
	proto.Unmarshal(s.Members, signed)
	proto.Unmarshal(signed.Payload, members)
	return members
}

func (s *saved) signAsMac(payload []byte) []byte {
	signed, err := keyring.Sign(payload, s.device("mac").KeyId, keyring.SoftwareSigner(ecdsaKey(s.Devices["mac"].Signing)))
	if err != nil {
		panic(err)
	}
	raw, _ := proto.Marshal(signed)
	return raw
}

func (s *saved) publishMembers(members *pb.Members) {
	s.Revisions[0]++
	members.Domain, members.Revision = keyring.MembersDomain, s.Revisions[0]
	payload, _ := proto.Marshal(members)
	s.Members = s.signAsMac(payload)
	s.MembersHistory = append(s.MembersHistory, s.Members)
}

// seal seals the made-up passwords to one opener, sealed by the Mac's reply key.
func (s *saved) seal(openerID string, publicKey []byte, automaticOnly bool) {
	for i, secret := range logins {
		if automaticOnly && catalogueLogins[i].Rule != pb.Rule_RULE_AUTOMATIC {
			continue
		}
		bound := proto.Clone(secret).(*pb.LoginSecret)
		bound.Title, bound.Sites = catalogueLogins[i].Title, catalogueLogins[i].Sites
		sealed, err := keyring.SealLogin(bound, catalogueLogins[i].Version, publicKey, openerID, s.device("mac").ReplyKeyId,
			keyring.SoftwareSigner(ecdsaKey(s.Devices["mac"].Reply)))
		if err != nil {
			panic(err)
		}
		raw, _ := proto.Marshal(sealed)
		s.Copies = append(s.Copies, raw)
	}
	s.Revisions[2]++
}

func (s *saved) copies() []*pb.SealedLogin {
	var copies []*pb.SealedLogin
	for _, raw := range s.Copies {
		sealed := &pb.SealedLogin{}
		proto.Unmarshal(raw, sealed)
		copies = append(copies, sealed)
	}
	return copies
}

// ---- init ---------------------------------------------------------------------

func newKey() []byte {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	raw, _ := x509.MarshalECPrivateKey(key)
	return raw
}

func newECDH() []byte {
	key, _ := ecdh.P256().GenerateKey(rand.Reader)
	return key.Bytes()
}

func (d *devices) initialise(doorAddress string) error {
	if _, err := netip.ParseAddrPort(doorAddress); err != nil {
		return errors.New("init needs --door IP:PORT")
	}
	if err := os.MkdirAll(d.dir, 0o700); err != nil {
		return err
	}
	return d.change(func(s *saved) error {
		s.Door = doorAddress
		var err error
		if s.MacCertificate, s.MacTLSKey, err = tlsid.New("Agent Keyring test Mac"); err != nil {
			return err
		}
		if s.PhoneCertificate, s.PhoneTLSKey, err = tlsid.New("Agent Keyring test iPhone"); err != nil {
			return err
		}
		for name := range labels {
			token := make([]byte, 32)
			rand.Read(token)
			s.Devices[name] = &keys{Signing: newKey(), Reply: newKey(), Opening: newECDH(), Notice: newECDH(), Token: token}
		}
		pushKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		s.PushKey, _ = x509.MarshalPKCS8PrivateKey(pushKey)
		s.publishMembers(&pb.Members{Devices: []*pb.Device{s.device("mac"), s.device("iphone"), s.device("watch")},
			Machines: []*pb.Machine{{MachineId: keyring.KeyID(s.macSPKI()), Label: labels["mac"], TlsPublicKey: s.macSPKI(),
				ReceivingPublicKey: ecdhKey(s.Devices["mac"].Opening).PublicKey().Bytes()}}})
		s.Revisions[1]++
		catalogue, _ := proto.Marshal(&pb.Catalogue{Domain: keyring.CatalogueDomain, Revision: s.Revisions[1], Logins: catalogueLogins, ImportedUnixSeconds: time.Now().Unix()})
		s.Catalogue = s.signAsMac(catalogue)
		s.seal(s.device("mac").KeyId, s.device("mac").OpeningPublicKey, false) // The Mac answers other computers' requests from its own copies.
		for _, name := range []string{"iphone", "watch"} {
			s.seal(s.device(name).KeyId, s.device(name).OpeningPublicKey, false)
			// Each device's push address, signed by the iPhone's reply key:
			// its own, and its Apple Watch's on the Watch's behalf.
			registration, _ := proto.Marshal(&pb.PushRegistration{Domain: keyring.PushDomain, DeviceKeyId: s.device(name).KeyId,
				ApnsToken: s.Devices[name].Token, ApnsTopic: topic, NoticePublicKey: ecdhKey(s.Devices[name].Notice).PublicKey().Bytes(),
				RegisteredUnixSeconds: time.Now().Unix()})
			signed, err := keyring.Sign(registration, s.device("iphone").ReplyKeyId, keyring.SoftwareSigner(ecdsaKey(s.Devices["iphone"].Reply)))
			if err != nil {
				return err
			}
			raw, _ := proto.Marshal(signed)
			s.Registrations = append(s.Registrations, raw)
		}
		fmt.Printf("The Mac, iPhone and Apple Watch are set up with %d made-up passwords.\n", len(logins))
		return nil
	})
}

// ---- The Mac's door ---------------------------------------------------------------

func (d *devices) serveMac(joinWithin time.Duration) error {
	s, err := d.read()
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", s.Door)
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v2/join", func(w http.ResponseWriter, r *http.Request) { d.join(w, r, joinWithin) })
	mux.HandleFunc("POST /v2/join/withdraw", d.withdraw)
	mux.HandleFunc("GET /v2/rev", func(w http.ResponseWriter, r *http.Request) {
		if s, machine := d.member(w, r); machine != nil {
			reply(w, &pb.Revisions{Members: s.Revisions[0], Catalogue: s.Revisions[1], Copies: s.Revisions[2]})
		}
	})
	mux.HandleFunc("GET /v2/bundle", func(w http.ResponseWriter, r *http.Request) {
		if s, machine := d.member(w, r); machine != nil {
			since, _ := strconv.ParseUint(r.URL.Query().Get("members"), 10, 64)
			reply(w, s.bundle(machine, since))
		}
	})
	mux.HandleFunc("POST /v2/complaint", func(w http.ResponseWriter, r *http.Request) {
		if _, machine := d.member(w, r); machine != nil {
			raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
			if proto.Unmarshal(raw, &pb.Complaint{}) != nil {
				http.Error(w, "The body must be a Complaint.", http.StatusBadRequest)
				return
			}
			d.change(func(s *saved) error { s.Complaints = append(s.Complaints, raw); return nil })
		}
	})
	mux.HandleFunc("GET /v2/complaints", func(w http.ResponseWriter, r *http.Request) {
		if s, machine := d.member(w, r); machine != nil {
			since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
			result := &pb.Complaints{}
			for _, raw := range s.Complaints {
				complaint := &pb.Complaint{}
				if proto.Unmarshal(raw, complaint) == nil && complaint.AtUnixSeconds >= since {
					result.Complaints = append(result.Complaints, complaint)
				}
			}
			reply(w, result)
		}
	})
	// Another computer's request, shown on the Mac as it is pushed to the devices.
	mux.HandleFunc("POST /v2/ask", func(w http.ResponseWriter, r *http.Request) {
		s, machine := d.member(w, r)
		if machine == nil {
			return
		}
		raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		signed := &pb.Signed{}
		if proto.Unmarshal(raw, signed) != nil {
			http.Error(w, "The body must be a signed Request.", http.StatusBadRequest)
			return
		}
		request, asking, err := keyring.CheckRequest(signed.Payload, signed.Signature, s.members())
		if err != nil || asking.MachineId != machine.MachineId || !bytes.Equal(request.AnswerTlsPublicKey, machine.TlsPublicKey) {
			http.Error(w, "A computer shows the Mac only a request it signed itself, naming its own door.", http.StatusForbidden)
			return
		}
		d.change(func(s *saved) error {
			if s.Asks[request.RequestId] == nil {
				s.Asks[request.RequestId] = raw
			}
			return nil
		})
		fmt.Printf("Shown on the Mac: %s from %q.\n", request.RequestId, machine.Label)
	})
	mux.HandleFunc("POST /v2/outcome", func(w http.ResponseWriter, r *http.Request) {
		if _, machine := d.member(w, r); machine != nil {
			raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
			lease := &pb.Lease{}
			if proto.Unmarshal(raw, lease) != nil || lease.RequestId == "" {
				http.Error(w, "The body must be a Lease.", http.StatusBadRequest)
				return
			}
			d.change(func(s *saved) error { s.Outcomes[lease.RequestId] = raw; return nil })
		}
	})
	// A Stop a device could not take to the asking computer's door, kept an hour.
	mux.HandleFunc("POST /v2/stop", func(w http.ResponseWriter, r *http.Request) {
		s, err := d.read()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		members := s.members()
		if !slices.ContainsFunc(members.Devices, func(device *pb.Device) bool {
			return len(device.TlsPublicKey) > 0 && bytes.Equal(device.TlsPublicKey, peerSPKI(r))
		}) {
			http.Error(w, "Only Josh's iPhone leaves a Stop here.", http.StatusForbidden)
			return
		}
		raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
		signed, end := &pb.Signed{}, &pb.EndRequest{}
		if proto.Unmarshal(raw, signed) != nil || proto.Unmarshal(signed.Payload, end) != nil || end.Domain != keyring.EndDomain {
			http.Error(w, "The body must be a signed EndRequest.", http.StatusBadRequest)
			return
		}
		device, err := keyring.Verify(signed, members, true)
		if err != nil || signed.SignerKeyId != device.ReplyKeyId || end.DeviceKeyId != device.KeyId {
			http.Error(w, "Stop is signed by the reply key of a device in Josh's list of devices.", http.StatusForbidden)
			return
		}
		d.change(func(s *saved) error { s.Stops[end.RequestId] = &keptStop{raw, time.Now().Unix()}; return nil })
		fmt.Printf("Kept a Stop for %s from %q.\n", end.RequestId, device.Label)
	})
	mux.HandleFunc("GET /v2/stops", func(w http.ResponseWriter, r *http.Request) {
		if s, machine := d.member(w, r); machine != nil {
			kept := s.Stops[r.URL.Query().Get("request")]
			if kept == nil || time.Since(time.Unix(kept.At, 0)) > time.Hour {
				http.Error(w, "No Stop is waiting for that request.", http.StatusNotFound)
				return
			}
			w.Write(kept.Signed)
		}
	})
	mux.HandleFunc("GET /v2/logs", func(w http.ResponseWriter, r *http.Request) {
		if _, machine := d.member(w, r); machine != nil {
			reply(w, &pb.Logs{Lines: []string{time.Now().UTC().Format("2006-01-02T15:04:05.000Z") + " Test_Mac mac logs asked"}})
		}
	})
	server := &http.Server{Handler: mux, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{s.macCertificate()},
		ClientAuth: tls.RequireAnyClientCert}}
	fmt.Println("The Mac's door is open at", s.Door)
	return server.ServeTLS(listener, "", "")
}

func reply(w http.ResponseWriter, message proto.Message) {
	raw, _ := proto.Marshal(message)
	w.Write(raw)
}

func peerSPKI(r *http.Request) []byte {
	if r.TLS == nil || len(r.TLS.PeerCertificates) != 1 {
		return nil
	}
	return r.TLS.PeerCertificates[0].RawSubjectPublicKeyInfo
}

// member is the computer calling, by its TLS key, if Members lists it.
func (d *devices) member(w http.ResponseWriter, r *http.Request) (*saved, *pb.Machine) {
	s, err := d.read()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return nil, nil
	}
	for _, m := range s.members().Machines {
		if bytes.Equal(m.TlsPublicKey, peerSPKI(r)) {
			return s, m
		}
	}
	http.Error(w, "This computer is not in Josh's list of computers.", http.StatusForbidden)
	return nil, nil
}

// bundle is what one computer keeps: the lists, the push addresses, the
// Apple Watch's copies and its own Automatic copies.
func (s *saved) bundle(machine *pb.Machine, since uint64) *pb.Bundle {
	members, catalogue := &pb.Signed{}, &pb.Signed{}
	proto.Unmarshal(s.Members, members)
	proto.Unmarshal(s.Catalogue, catalogue)
	b := &pb.Bundle{Members: members, Catalogue: catalogue, Revisions: &pb.Revisions{Members: s.Revisions[0], Catalogue: s.Revisions[1], Copies: s.Revisions[2]}}
	for i, raw := range s.MembersHistory {
		if uint64(i+1) > since { // Revision i+1.
			revision := &pb.Signed{}
			proto.Unmarshal(raw, revision)
			b.MembersSince = append(b.MembersSince, revision)
		}
	}
	for _, raw := range s.Registrations {
		signed := &pb.Signed{}
		proto.Unmarshal(raw, signed)
		b.PushRegistrations = append(b.PushRegistrations, signed)
	}
	var watch string
	for _, device := range s.members().Devices {
		if device.Kind == pb.DeviceKind_DEVICE_KIND_WATCH {
			watch = device.KeyId
		}
	}
	for _, sealed := range s.copies() {
		if (watch != "" && sealed.OpenerId == watch) || sealed.OpenerId == machine.MachineId {
			b.Copies = append(b.Copies, sealed)
		}
	}
	return b
}

func readJoin(w http.ResponseWriter, r *http.Request) (*pb.JoinRequest, *pb.Machine) {
	raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<16))
	request := &pb.JoinRequest{}
	if proto.Unmarshal(raw, request) != nil || request.GetMachine() == nil {
		http.Error(w, "The body must be a computer's JoinRequest.", http.StatusBadRequest)
		return nil, nil
	}
	m := request.GetMachine()
	if !bytes.Equal(m.TlsPublicKey, peerSPKI(r)) || m.MachineId != keyring.KeyID(m.TlsPublicKey) {
		http.Error(w, "A computer joins with its own TLS key.", http.StatusForbidden)
		return nil, nil
	}
	return request, m
}

// join takes a computer's join, then answers once it is decided or after 25
// seconds still waiting. A second computer proving the same invitation
// withdraws both.
func (d *devices) join(w http.ResponseWriter, r *http.Request, joinWithin time.Duration) {
	request, m := readJoin(w, r)
	if request == nil {
		return
	}
	err := d.change(func(s *saved) error {
		if s.Joins[m.MachineId] != nil {
			return nil // Posted again while it waits.
		}
		var secret []byte
		for _, candidate := range s.Secrets {
			if hmac.Equal(keyring.JoinProof(candidate, request), request.Proof) {
				secret = candidate
			}
		}
		if secret == nil {
			for _, other := range s.Joins {
				if hmac.Equal(keyring.JoinProof(other.Secret, request), request.Proof) && other.State == pb.JoinState_JOIN_STATE_WAITING {
					other.State = pb.JoinState_JOIN_STATE_WITHDRAWN
					raw, _ := proto.Marshal(request)
					s.Joins[m.MachineId] = &join{Request: raw, Secret: other.Secret, Asked: time.Now().Unix(), State: pb.JoinState_JOIN_STATE_WITHDRAWN}
					return nil
				}
			}
			return errors.New("This join does not prove an invitation of this Mac's.")
		}
		s.Secrets = slices.DeleteFunc(s.Secrets, func(candidate []byte) bool { return bytes.Equal(candidate, secret) })
		raw, _ := proto.Marshal(request)
		s.Joins[m.MachineId] = &join{Request: raw, Secret: secret, Asked: time.Now().Unix(), State: pb.JoinState_JOIN_STATE_WAITING}
		return nil
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}
	for deadline := time.Now().Add(25 * time.Second); ; time.Sleep(100 * time.Millisecond) {
		var status *pb.JoinStatus
		d.change(func(s *saved) error {
			j := s.Joins[m.MachineId]
			if j.State == pb.JoinState_JOIN_STATE_WAITING && time.Since(time.Unix(j.Asked, 0)) > joinWithin {
				j.State = pb.JoinState_JOIN_STATE_EXPIRED
			}
			status = &pb.JoinStatus{State: j.State}
			switch j.State {
			case pb.JoinState_JOIN_STATE_APPROVED:
				status.Members = &pb.Signed{}
				proto.Unmarshal(s.Members, status.Members)
				sealed, err := keyring.SealPushCredential(&pb.PushCredential{TeamId: teamID, KeyId: pushKeyID, PrivateKey: s.PushKey}, m.ReceivingPublicKey, m.MachineId)
				if err != nil {
					return err
				}
				status.PushCredential = sealed
			case pb.JoinState_JOIN_STATE_REFUSED:
				status.Refusal = &pb.JoinRefusal{}
				proto.Unmarshal(j.Refusal, status.Refusal)
			}
			return nil
		})
		if status.State != pb.JoinState_JOIN_STATE_WAITING || time.Now().After(deadline) || r.Context().Err() != nil {
			reply(w, status)
			return
		}
	}
}

func (d *devices) withdraw(w http.ResponseWriter, r *http.Request) {
	request, m := readJoin(w, r)
	if request == nil {
		return
	}
	d.change(func(s *saved) error {
		if j := s.Joins[m.MachineId]; j != nil && j.State == pb.JoinState_JOIN_STATE_WAITING {
			j.State = pb.JoinState_JOIN_STATE_WITHDRAWN
			fmt.Printf("%q withdrew its join.\n", m.Label)
		}
		return nil
	})
	reply(w, &pb.Empty{})
}

// invite makes a one-time invitation, as the Mac does for a computer. host
// replaces the door's address, to test an invitation naming a name or an
// address off the tailnet.
func (d *devices) invite(host string) error {
	return d.change(func(s *saved) error {
		doorHost, portText, _ := net.SplitHostPort(s.Door)
		if host != "" {
			doorHost = host
		}
		port, _ := strconv.Atoi(portText)
		secret := make([]byte, 32)
		rand.Read(secret)
		s.Secrets = append(s.Secrets, secret)
		raw, _ := proto.Marshal(&pb.JoinInvite{InviterKeyId: s.device("mac").KeyId, InviterLabel: labels["mac"], Secret: secret,
			ExpiresUnixSeconds: time.Now().Add(10 * time.Minute).Unix(), DoorHost: doorHost, DoorPort: uint32(port), DoorTlsPublicKey: s.macSPKI()})
		fmt.Println("agentkeyring://join?invite=" + base64.RawURLEncoding.EncodeToString(raw))
		return nil
	})
}

// decideJoins approves every waiting computer, Automatic allowed, or refuses
// each with words its invitation's secret vouches for.
func (d *devices) decideJoins(approve bool, words string) error {
	return d.change(func(s *saved) error {
		decided := 0
		members := s.members()
		for _, j := range s.Joins {
			if j.State != pb.JoinState_JOIN_STATE_WAITING {
				continue
			}
			request := &pb.JoinRequest{}
			proto.Unmarshal(j.Request, request)
			m := request.GetMachine()
			if approve {
				m.AutomaticAllowed = true
				members.Machines = append(members.Machines, m)
				s.seal(m.MachineId, m.ReceivingPublicKey, true)
				j.State = pb.JoinState_JOIN_STATE_APPROVED
				fmt.Printf("Approved %q.\n", m.Label)
			} else {
				j.Refusal, _ = proto.Marshal(&pb.JoinRefusal{JoinerId: m.MachineId, Key: keyring.RefusalKey(j.Secret, m.MachineId), Reply: words,
					ReplyProof: keyring.RefusalReplyProof(j.Secret, m.MachineId, words)})
				j.State = pb.JoinState_JOIN_STATE_REFUSED
				fmt.Printf("Refused %q.\n", m.Label)
			}
			decided++
		}
		if decided == 0 {
			return errors.New("nothing is waiting to join")
		}
		if approve {
			s.publishMembers(members)
		}
		return nil
	})
}

// remove takes a device off Josh's list, with its copies and push address.
func (d *devices) remove(name string) error {
	return d.change(func(s *saved) error {
		gone := s.device(name)
		members := s.members()
		members.Devices = slices.DeleteFunc(members.Devices, func(device *pb.Device) bool { return device.KeyId == gone.KeyId })
		s.publishMembers(members)
		s.Copies = slices.DeleteFunc(s.Copies, func(raw []byte) bool {
			sealed := &pb.SealedLogin{}
			proto.Unmarshal(raw, sealed)
			return sealed.OpenerId == gone.KeyId
		})
		s.Revisions[2]++
		fmt.Printf("Removed %s.\n", gone.Label)
		return nil
	})
}

// ---- Apple's push service ----------------------------------------------------------

// serveApple stands in for Apple's push service: it checks each push's token
// signature against the made-up push key, and writes each push to
// DIR/pushes/DEVICE/ for the stand-in devices to receive.
func (d *devices) serveApple(listen string) error {
	s, err := d.read()
	if err != nil {
		return err
	}
	address, err := netip.ParseAddrPort(listen)
	if err != nil || !address.Addr().IsLoopback() {
		return errors.New("apple needs --listen with a loopback IP:PORT")
	}
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Stand-in for Apple's push service"},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(24 * time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses: []net.IP{net.IP(address.Addr().AsSlice())}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return err
	}
	certificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	private, _ := x509.MarshalECPrivateKey(key)
	certificate, err := tls.X509KeyPair(certificatePEM, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: private}))
	if err != nil {
		return err
	}
	parsed, _ := x509.ParsePKCS8PrivateKey(s.PushKey)
	pushPublic := &parsed.(*ecdsa.PrivateKey).PublicKey
	tokens := map[string]string{}
	for name, k := range s.Devices {
		tokens[hex.EncodeToString(k.Token)] = name
	}
	listener, err := net.Listen("tcp", listen)
	if err != nil {
		return err
	}
	var tokenLock sync.Mutex
	var lastToken string
	var lastTokenAt time.Time
	server := &http.Server{TLSConfig: &tls.Config{Certificates: []tls.Certificate{certificate}, NextProtos: []string{"h2"}},
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.ProtoMajor != 2 || !validToken(strings.TrimPrefix(r.Header.Get("authorization"), "bearer "), pushPublic) {
				w.WriteHeader(http.StatusForbidden)
				io.WriteString(w, `{"reason":"InvalidProviderToken"}`)
				return
			}
			// As Apple does: a new provider token within 20 minutes of the last is refused.
			providerToken := r.Header.Get("authorization")
			tokenLock.Lock()
			tooSoon := lastToken != "" && providerToken != lastToken && time.Since(lastTokenAt) < 20*time.Minute
			if !tooSoon && providerToken != lastToken {
				lastToken, lastTokenAt = providerToken, time.Now()
			}
			tokenLock.Unlock()
			if tooSoon {
				w.WriteHeader(http.StatusTooManyRequests)
				io.WriteString(w, `{"reason":"TooManyProviderTokenUpdates"}`)
				return
			}
			token := r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:]
			name := tokens[token]
			if name == "" || r.Header.Get("apns-topic") != topic {
				w.WriteHeader(http.StatusBadRequest)
				io.WriteString(w, `{"reason":"BadDeviceToken"}`)
				return
			}
			payload, _ := io.ReadAll(io.LimitReader(r.Body, 8192))
			record, _ := json.Marshal(map[string]any{"visible": r.Header.Get("apns-push-type") == "alert", "collapse": r.Header.Get("apns-collapse-id"),
				"payload": json.RawMessage(payload)})
			folder := filepath.Join(d.dir, "pushes", name)
			os.MkdirAll(folder, 0o700)
			os.WriteFile(filepath.Join(folder, fmt.Sprintf("%020d.json", time.Now().UnixNano())), record, 0o600)
			w.WriteHeader(http.StatusOK)
		})}
	if err := os.WriteFile(filepath.Join(d.dir, "apple-ca.pem"), certificatePEM, 0o600); err != nil {
		return err
	}
	fmt.Println("The stand-in for Apple is listening at", listen)
	return server.ServeTLS(listener, "", "")
}

// validToken checks the ES256 token Apple requires against the made-up push key.
func validToken(token string, public *ecdsa.PublicKey) bool {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return false
	}
	var header struct{ Alg, Kid string }
	var claims struct {
		Iss string `json:"iss"`
	}
	rawHeader, _ := base64.RawURLEncoding.DecodeString(parts[0])
	rawClaims, _ := base64.RawURLEncoding.DecodeString(parts[1])
	signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if json.Unmarshal(rawHeader, &header) != nil || json.Unmarshal(rawClaims, &claims) != nil || len(signature) != 64 ||
		header.Alg != "ES256" || header.Kid != pushKeyID || claims.Iss != teamID {
		return false
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	return ecdsa.Verify(public, digest[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:]))
}

// ---- The iPhone and the Apple Watch ---------------------------------------------------

type push struct {
	path    string
	visible bool
	work    *pb.Work
	request *pb.Request
}

// pushes is every push Apple delivered to a device so far, oldest first,
// each opened with the device's notice key.
func (d *devices) pushes(s *saved, name string) ([]push, error) {
	folder := filepath.Join(d.dir, "pushes", name)
	entries, _ := os.ReadDir(folder)
	var names []string
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	var found []push
	for _, file := range names {
		raw, err := os.ReadFile(filepath.Join(folder, file))
		if err != nil {
			return nil, err
		}
		var record struct {
			Visible bool `json:"visible"`
			Payload struct {
				Akr string `json:"akr"`
			} `json:"payload"`
		}
		if err := json.Unmarshal(raw, &record); err != nil {
			return nil, err
		}
		sealed, _ := base64.StdEncoding.DecodeString(record.Payload.Akr)
		notice := &pb.Notice{}
		if err := proto.Unmarshal(sealed, notice); err != nil {
			return nil, err
		}
		work, err := keyring.OpenNotice(notice, ecdhKey(s.Devices[name].Notice), s.device(name).KeyId)
		if err != nil {
			return nil, fmt.Errorf("cannot open the push: %w", err)
		}
		request, err := keyring.ParseRequest(work.Request)
		if err != nil {
			return nil, err
		}
		found = append(found, push{filepath.Join(folder, file), record.Visible, work, request})
	}
	return found, nil
}

// next waits for a push to a device that matches.
func (d *devices) next(name string, match func(push) bool) (*saved, push, error) {
	return d.pick(name, func(found []push) []push { return found }, match)
}

// pick is next over the pushes before() keeps.
func (d *devices) pick(name string, before func([]push) []push, match func(push) bool) (*saved, push, error) {
	for deadline := time.Now().Add(30 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		s, err := d.read()
		if err != nil {
			return nil, push{}, err
		}
		found, err := d.pushes(s, name)
		if err != nil {
			return nil, push{}, err
		}
		for _, p := range before(found) {
			if match(p) {
				return s, p, nil
			}
		}
	}
	return nil, push{}, fmt.Errorf("no such push reached the %s in 30 seconds", name)
}

// doorRetry is how long a post to a computer's door retries: 30 seconds, as
// the apps do; a test may shorten it (--door-retry).
var doorRetry = 30 * time.Second

// toDoor posts to the asking computer's door, the address and key its signed
// request names, as the apps do: it retries for doorRetry while nothing
// answers there, and never after a refusal.
func toDoor(ctx context.Context, request *pb.Request, path string, body proto.Message) (int, []byte, error) {
	host, _, err := net.SplitHostPort(request.AnswerAddress)
	if ip, e := netip.ParseAddr(host); err != nil || e != nil || !(ip.IsLoopback() || netip.MustParsePrefix("100.64.0.0/10").Contains(ip) ||
		netip.MustParsePrefix("fd7a:115c:a1e0::/48").Contains(ip)) {
		return 0, nil, fmt.Errorf("refused: the request's door %q is not a Tailscale address", request.AnswerAddress)
	}
	pinned := request.AnswerTlsPublicKey
	client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13, InsecureSkipVerify: true,
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 || !bytes.Equal(state.PeerCertificates[0].RawSubjectPublicKeyInfo, pinned) {
				return errors.New("the door's key is not the one the request names")
			}
			return nil
		}}}}
	raw, _ := proto.Marshal(body)
	for deadline := time.Now().Add(doorRetry); ; time.Sleep(250 * time.Millisecond) {
		response, err := client.Post("https://"+request.AnswerAddress+path, "application/octet-stream", bytes.NewReader(raw))
		if err == nil {
			defer response.Body.Close()
			text, _ := io.ReadAll(response.Body)
			return response.StatusCode, text, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return 0, nil, err
		}
	}
}

// answer takes the oldest request pushed to this device that it has not yet
// seen, and answers it at the asking computer's door, as the app does.
func (d *devices) answer(ctx context.Context, name, requestID string, approve bool, deny string, denyPlain, ignore bool) error {
	if labels[name] == "" || name == "mac" {
		return errors.New("--device is iphone or watch")
	}
	ended := map[string]bool{} // A request whose outcome came is no longer shown, as on the devices.
	s, p, err := d.pick(name, func(found []push) []push {
		clear(ended)
		for _, p := range found {
			if p.work.Outcome != nil {
				ended[p.request.RequestId] = true
			}
		}
		return found
	}, func(p push) bool {
		if requestID != "" {
			return p.visible && p.request.RequestId == requestID
		}
		_, err := os.Stat(p.path + ".seen")
		return p.visible && os.IsNotExist(err) && !ended[p.request.RequestId]
	})
	if err != nil {
		return err
	}
	os.WriteFile(p.path+".seen", nil, 0o600)
	request := p.request
	fmt.Printf("Request %s: %s wants %s: %q\n", request.RequestId, request.Agent, request.LoginId, request.Reason)
	self := s.device(name)
	k := s.Devices[name]
	// It arrived: the Apple Watch signs the note with its reply key; a locked
	// iPhone's notification extension cannot, and names its push address.
	arrival, _ := proto.Marshal(&pb.Arrival{Domain: keyring.ArrivalDomain, RequestId: request.RequestId, DeviceKeyId: self.KeyId,
		ArrivedUnixSeconds: time.Now().Unix(), PushTokenSha256: keyring.SHA256(k.Token)})
	note := &pb.Signed{Payload: arrival}
	if name == "watch" {
		if note, err = keyring.Sign(arrival, self.ReplyKeyId, keyring.SoftwareSigner(ecdsaKey(k.Reply))); err != nil {
			return err
		}
	}
	if status, text, err := toDoor(ctx, request, "/v2/arrived", note); err != nil || status != http.StatusOK {
		fmt.Printf("The arrival was not taken (%d %s): %v\n", status, text, err) // A timing note: the answer goes on.
	}
	var upload *pb.AnswerUpload
	switch {
	case ignore:
		fmt.Println("Left unanswered.")
		return nil
	case denyPlain:
		upload = &pb.AnswerUpload{DenyRequestId: request.RequestId}
	case deny != "":
		upload, err = keyring.Deny(p.work.Request, deny, self.ReplyKeyId, keyring.SoftwareSigner(ecdsaKey(k.Reply)), time.Now())
	case approve:
		members := s.members()
		_, asking, err := keyring.CheckRequest(p.work.Request, p.work.RequestSignature, members)
		if err != nil {
			return fmt.Errorf("refused: the request was not signed by the computer it names: %w", err)
		}
		if !bytes.Equal(asking.TlsPublicKey, request.AnswerTlsPublicKey) {
			return errors.New("refused: the request's door key is not the computer's")
		}
		listed := catalogueLogins[slices.IndexFunc(catalogueLogins, func(l *pb.Login) bool { return l.LoginId == request.LoginId })]
		sealed := p.work.SealedLogin // The Apple Watch's copy comes in the push;
		if name == "iphone" {        // the iPhone keeps its own.
			for _, own := range s.copies() {
				if own.OpenerId == self.KeyId && own.LoginId == request.LoginId {
					sealed = own
				}
			}
		}
		if sealed == nil {
			return errors.New("cannot approve: no sealed copy of this password for this device")
		}
		if err := keyring.CheckSealed(sealed, members, listed); err != nil {
			return fmt.Errorf("refused: a copy no device signed, or an old one: %w", err)
		}
		secret, err := keyring.OpenLogin(sealed, ecdhKey(k.Opening))
		if err != nil {
			return err
		}
		upload, err = keyring.Approve(p.work.Request, secret, listed.Sites, asking.ReceivingPublicKey, self.KeyId, keyring.SoftwareSigner(ecdsaKey(k.Signing)), time.Now())
		if err != nil {
			return err
		}
	default:
		return errors.New("choose --approve, --deny WORDS, --deny-plain or --ignore")
	}
	if err != nil {
		return err
	}
	status, text, err := toDoor(ctx, request, "/v2/answer", upload)
	if err != nil {
		return fmt.Errorf("the computer's door did not answer for 30 seconds: %w", err)
	}
	if status != http.StatusOK {
		return fmt.Errorf("the door refused (%d): %s", status, text)
	}
	lease := &pb.Lease{}
	proto.Unmarshal(text, lease)
	fmt.Printf("The door says: %s by %s\n", lease.State, lease.AnsweredBy)
	return nil
}

// outcome waits for the silent push that tells this device how a request ended.
func (d *devices) outcome(name, requestID string) error {
	_, p, err := d.next(name, func(p push) bool { return !p.visible && p.request.RequestId == requestID && p.work.Outcome != nil })
	if err != nil {
		return err
	}
	fmt.Printf("Outcome: %s by %s\n", p.work.Outcome.State, p.work.Outcome.AnsweredBy)
	return nil
}

// stop is Stop on a device: an EndRequest signed by its reply key, posted to
// the door the request names. If nobody holds that door, the approval ends
// by itself at its time.
func (d *devices) stop(ctx context.Context, name, requestID string) error {
	s, p, err := d.next(name, func(p push) bool { return p.request.RequestId == requestID })
	if err != nil {
		return err
	}
	self := s.device(name)
	payload, _ := proto.Marshal(&pb.EndRequest{Domain: keyring.EndDomain, RequestId: requestID, DeviceKeyId: self.KeyId, EndedUnixSeconds: time.Now().Unix()})
	signed, err := keyring.Sign(payload, self.ReplyKeyId, keyring.SoftwareSigner(ecdsaKey(s.Devices[name].Reply)))
	if err != nil {
		return err
	}
	status, text, err := toDoor(ctx, p.request, "/v2/end", signed)
	if err != nil {
		// Nobody holds that computer's door: the Stop waits at the Mac, which the
		// computer asks before its agents next use the approval. The iPhone
		// carries it there over its own connection, the Apple Watch's too.
		if status, text, err := s.toMacAsPhone("/v2/stop", signed); err != nil || status != http.StatusOK {
			return fmt.Errorf("the computer's door did not answer, and the Mac did not keep the Stop (%d %s): %v", status, text, err)
		}
		fmt.Println("Left the Stop at the Mac.")
		return nil
	}
	if status != http.StatusOK {
		return fmt.Errorf("the door refused (%d): %s", status, text)
	}
	lease := &pb.Lease{}
	proto.Unmarshal(text, lease)
	fmt.Printf("Stopped: %s by %s\n", lease.State, lease.EndedBy)
	return nil
}

// toMacAsPhone posts to the Mac's members' door with the iPhone's TLS key,
// the Mac's key pinned.
func (s *saved) toMacAsPhone(path string, body proto.Message) (int, []byte, error) {
	pinned := s.macSPKI()
	client := &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS13,
		InsecureSkipVerify: true, Certificates: []tls.Certificate{s.phoneCertificate()},
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 || !bytes.Equal(state.PeerCertificates[0].RawSubjectPublicKeyInfo, pinned) {
				return errors.New("the Mac's key is not the one pinned")
			}
			return nil
		}}}}
	raw, _ := proto.Marshal(body)
	response, err := client.Post("https://"+s.Door+path, "application/octet-stream", bytes.NewReader(raw))
	if err != nil {
		return 0, nil, err
	}
	defer response.Body.Close()
	text, _ := io.ReadAll(response.Body)
	return response.StatusCode, text, nil
}

// macAnswer is Josh answering, on the Mac, another computer's request the Mac
// was shown: the named one, or one still waiting there. As a device
// does: it checks the request against the Mac's list, opens the Mac's own copy,
// seals it for the asking computer, and posts the answer to its door. The door's
// reply is the request's Lease: this answer's, or the one that ended it first.
func (d *devices) macAnswer(ctx context.Context, requestID string, approve bool, deny string) error {
	if !approve && deny == "" {
		return errors.New("choose --approve or --deny WORDS")
	}
	var s *saved
	var signed *pb.Signed
	for deadline := time.Now().Add(30 * time.Second); signed == nil; time.Sleep(100 * time.Millisecond) {
		if time.Now().After(deadline) {
			return errors.New("no request was shown on the Mac in 30 seconds")
		}
		err := d.change(func(saved *saved) error {
			s = saved
			ids := make([]string, 0, len(saved.Asks))
			for id := range saved.Asks {
				ids = append(ids, id)
			}
			sort.Strings(ids)
			for _, id := range ids {
				// With no id: one still waiting, as the panel shows only those.
				if (requestID != "" && id == requestID) || (requestID == "" && !saved.MacAnswers[id] && saved.Outcomes[id] == nil) {
					signed = &pb.Signed{}
					proto.Unmarshal(saved.Asks[id], signed)
					saved.MacAnswers[id] = true
					return nil
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	members := s.members()
	request, asking, err := keyring.CheckRequest(signed.Payload, signed.Signature, members)
	if err != nil {
		return fmt.Errorf("refused: the request was not signed by the computer it names: %w", err)
	}
	fmt.Printf("Request %s: %s on %s wants %s: %q\n", request.RequestId, request.Agent, asking.Label, request.LoginId, request.Reason)
	mac := s.device("mac")
	var upload *pb.AnswerUpload
	if approve {
		listed := catalogueLogins[slices.IndexFunc(catalogueLogins, func(l *pb.Login) bool { return l.LoginId == request.LoginId })]
		var sealed *pb.SealedLogin
		for _, own := range s.copies() {
			if own.OpenerId == mac.KeyId && own.LoginId == request.LoginId {
				sealed = own
			}
		}
		if sealed == nil || keyring.CheckSealed(sealed, members, listed) != nil {
			return errors.New("cannot approve: the Mac has no good copy of this password")
		}
		secret, err := keyring.OpenLogin(sealed, ecdhKey(s.Devices["mac"].Opening))
		if err != nil {
			return err
		}
		upload, err = keyring.Approve(signed.Payload, secret, listed.Sites, asking.ReceivingPublicKey, mac.KeyId,
			keyring.SoftwareSigner(ecdsaKey(s.Devices["mac"].Signing)), time.Now())
		if err != nil {
			return err
		}
	} else if upload, err = keyring.Deny(signed.Payload, deny, mac.ReplyKeyId, keyring.SoftwareSigner(ecdsaKey(s.Devices["mac"].Reply)), time.Now()); err != nil {
		return err
	}
	status, text, err := toDoor(ctx, request, "/v2/answer", upload)
	if err != nil {
		return fmt.Errorf("the computer's door did not answer: %w", err)
	}
	if status != http.StatusOK {
		return fmt.Errorf("the door refused (%d): %s", status, text)
	}
	lease := &pb.Lease{}
	proto.Unmarshal(text, lease)
	fmt.Printf("The door says: %s by %s\n", lease.State, lease.AnsweredBy)
	return nil
}

// macOutcome waits for the asking computer to tell the Mac how its request ended.
func (d *devices) macOutcome(requestID string) error {
	for deadline := time.Now().Add(30 * time.Second); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		s, err := d.read()
		if err != nil {
			return err
		}
		if raw := s.Outcomes[requestID]; raw != nil {
			lease := &pb.Lease{}
			proto.Unmarshal(raw, lease)
			fmt.Printf("Outcome: %s by %s\n", lease.State, lease.AnsweredBy)
			return nil
		}
	}
	return errors.New("the Mac heard no outcome for that request in 30 seconds")
}
