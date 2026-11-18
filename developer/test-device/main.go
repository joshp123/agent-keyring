// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// A stand-in for an approving device, with software keys where an iPhone has
// its chip, for end-to-end tests of the relay and the command. It does what
// the iPhone app does over the same protocol, with made-up logins only.
//
//	test-device init    --state DIR --relay HOST:PORT   create keys, members, catalogue, sealed logins
//	test-device approve-joins --state DIR               approve every waiting machine, Automatic allowed
//	test-device answer  --state DIR (--approve | --deny WORDS | --deny-plain | --ignore)
//	                                                    answer the next waiting request
package main

import (
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"github.com/joshp123/agent-keyring/internal/tlsid"
	"github.com/joshp123/agent-keyring/internal/wire"
	"google.golang.org/protobuf/proto"
)

// The made-up logins. "example.com" asks; "automatic.example" is Automatic.
var logins = []*pb.LoginSecret{
	{LoginId: "login-ask", Username: "agent@example.com", Password: "example-ask-password", TotpSeed: []byte("12345678901234567890")},
	{LoginId: "login-automatic", Username: "agent@automatic.example", Password: "example-automatic-password"},
}

var catalogueLogins = []*pb.Login{
	{LoginId: "login-ask", Title: "Example", Sites: []string{"https://example.com"}, Account: "agent@example.com", HasOneTimeCode: true, Rule: pb.Rule_RULE_ASK},
	{LoginId: "login-automatic", Title: "Automatic example", Sites: []string{"https://automatic.example"}, Account: "agent@automatic.example", Rule: pb.Rule_RULE_AUTOMATIC},
}

type saved struct {
	Relay       string `json:"relay"`
	RelaySPKI   []byte `json:"relay_spki"`
	Certificate []byte `json:"certificate"`
	TLSKey      []byte `json:"tls_key"`
	Signing     []byte `json:"signing"`
	Reply       []byte `json:"reply"`
	Opening     []byte `json:"opening"`
	Revision    uint64 `json:"revision"`
}

type device struct {
	saved
	path        string
	certificate tls.Certificate
	signing     *ecdsa.PrivateKey
	reply       *ecdsa.PrivateKey
	opening     *ecdh.PrivateKey
	self        *pb.Device
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: test-device init|approve-joins|answer --state DIR ...")
		os.Exit(2)
	}
	flags := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	state := flags.String("state", "", "state directory")
	relay := flags.String("relay", "", "relay HOST:PORT (init)")
	approve := flags.Bool("approve", false, "approve the next request")
	deny := flags.String("deny", "", "deny the next request with these words")
	denyPlain := flags.Bool("deny-plain", false, "deny the next request with no words")
	ignore := flags.Bool("ignore", false, "see the next request and leave it unanswered")
	flags.Parse(os.Args[2:])
	ctx, cancel := context.WithTimeout(context.Background(), 11*time.Minute)
	defer cancel()
	var err error
	switch os.Args[1] {
	case "init":
		err = initialise(ctx, *state, *relay)
	case "approve-joins":
		err = withDevice(*state, func(d *device) error { return d.approveJoins(ctx) })
	case "answer":
		err = withDevice(*state, func(d *device) error { return d.answer(ctx, *approve, *deny, *denyPlain, *ignore) })
	default:
		err = errors.New("unknown command")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "test-device:", err)
		os.Exit(1)
	}
}

func ecdsaKey(raw []byte) (*ecdsa.PrivateKey, error) {
	key, err := x509.ParseECPrivateKey(raw)
	return key, err
}

func publicBytes(key *ecdsa.PrivateKey) []byte {
	return elliptic.Marshal(elliptic.P256(), key.X, key.Y) //nolint:staticcheck // X9.63 uncompressed, as CryptoKit writes.
}

func initialise(ctx context.Context, directory, relay string) error {
	if directory == "" || relay == "" {
		return errors.New("init needs --state and --relay")
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	certificate, tlsKey, err := tlsid.New("Agent Keyring test device")
	if err != nil {
		return err
	}
	generate := func() []byte {
		key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		raw, _ := x509.MarshalECPrivateKey(key)
		return raw
	}
	opening, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	d := &device{saved: saved{Relay: relay, Certificate: certificate, TLSKey: tlsKey, Signing: generate(), Reply: generate(), Opening: opening.Bytes()},
		path: filepath.Join(directory, "device.json")}
	if err := d.load(); err != nil {
		return err
	}
	var observed []byte
	if _, err := d.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Members{Members: &pb.Empty{}}}, &observed); err != nil && observed == nil {
		return err
	}
	d.RelaySPKI = observed
	members := &pb.Members{Domain: keyring.MembersDomain, Revision: 1, Devices: []*pb.Device{d.self}, RelayTlsPublicKey: observed}
	if err := d.publishMembers(ctx, members); err != nil {
		return err
	}
	catalogue, _ := proto.Marshal(&pb.Catalogue{Domain: keyring.CatalogueDomain, Revision: 1, Logins: catalogueLogins, ImportedUnixSeconds: time.Now().Unix()})
	signed, err := keyring.Sign(catalogue, d.self.KeyId, keyring.SoftwareSigner(d.signing))
	if err != nil {
		return err
	}
	if _, err := d.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_PublishCatalogue{PublishCatalogue: signed}}, nil); err != nil {
		return err
	}
	if err := d.seal(ctx, d.self.KeyId, d.opening.PublicKey().Bytes(), false); err != nil {
		return err
	}
	fmt.Printf("Device %s set up the relay with %d made-up logins.\n", d.self.KeyId[:16], len(logins))
	return d.write()
}

func withDevice(directory string, run func(*device) error) error {
	raw, err := os.ReadFile(filepath.Join(directory, "device.json"))
	if err != nil {
		return err
	}
	d := &device{path: filepath.Join(directory, "device.json")}
	if err := json.Unmarshal(raw, &d.saved); err != nil {
		return err
	}
	if err := d.load(); err != nil {
		return err
	}
	if err := run(d); err != nil {
		return err
	}
	return d.write()
}

func (d *device) load() (err error) {
	if d.certificate, err = tls.X509KeyPair(d.Certificate, d.TLSKey); err != nil {
		return err
	}
	if d.signing, err = ecdsaKey(d.Signing); err != nil {
		return err
	}
	if d.reply, err = ecdsaKey(d.Reply); err != nil {
		return err
	}
	if d.opening, err = ecdh.P256().NewPrivateKey(d.Opening); err != nil {
		return err
	}
	spki, err := tlsid.SPKI(d.certificate)
	if err != nil {
		return err
	}
	d.self = &pb.Device{KeyId: keyring.KeyID(publicBytes(d.signing)), Kind: pb.DeviceKind_DEVICE_KIND_IPHONE, Label: "Test iPhone",
		SigningPublicKey: publicBytes(d.signing), OpeningPublicKey: d.opening.PublicKey().Bytes(), TlsPublicKey: spki,
		ReplyKeyId: keyring.KeyID(publicBytes(d.reply)), ReplyPublicKey: publicBytes(d.reply)}
	return nil
}

func (d *device) write() error {
	raw, err := json.Marshal(&d.saved)
	if err != nil {
		return err
	}
	return os.WriteFile(d.path, raw, 0o600)
}

func (d *device) stream(ctx context.Context, request *pb.RelayRequest, observed *[]byte, receive func(*pb.RelayResponse) bool) error {
	dialer := tls.Dialer{NetDialer: &net.Dialer{Timeout: 5 * time.Second}, Config: tlsid.Client(d.certificate, d.RelaySPKI, observed)}
	conn, err := dialer.DialContext(ctx, "tcp", d.Relay)
	if err != nil {
		return err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	if err := wire.Write(conn, request); err != nil {
		return err
	}
	for {
		response := &pb.RelayResponse{}
		if err := wire.Read(conn, response); err != nil {
			return err
		}
		if failure := response.GetError(); failure != nil {
			return errors.New(failure.Message)
		}
		if !receive(response) || response.EndOfStream {
			return nil
		}
	}
}

func (d *device) call(ctx context.Context, request *pb.RelayRequest, observed *[]byte) (*pb.RelayResponse, error) {
	var result *pb.RelayResponse
	err := d.stream(ctx, request, observed, func(response *pb.RelayResponse) bool { result = response; return false })
	return result, err
}

func (d *device) members(ctx context.Context) (*pb.Members, error) {
	response, err := d.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Members{Members: &pb.Empty{}}}, nil)
	if err != nil {
		return nil, err
	}
	members := &pb.Members{}
	return members, proto.Unmarshal(response.GetSigned().GetPayload(), members)
}

func (d *device) publishMembers(ctx context.Context, members *pb.Members) error {
	raw, _ := proto.Marshal(members)
	signed, err := keyring.Sign(raw, d.self.KeyId, keyring.SoftwareSigner(d.signing))
	if err != nil {
		return err
	}
	_, err = d.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_PublishMembers{PublishMembers: signed}}, nil)
	d.Revision = members.Revision
	return err
}

// seal seals the made-up logins to one opener: this device, or, with
// automaticOnly, a machine allowed to use Automatic logins.
func (d *device) seal(ctx context.Context, openerID string, key []byte, automaticOnly bool) error {
	batch := &pb.SealedLogins{}
	for i, secret := range logins {
		if automaticOnly && catalogueLogins[i].Rule != pb.Rule_RULE_AUTOMATIC {
			continue
		}
		sealed, err := keyring.SealLogin(secret, key, openerID)
		if err != nil {
			return err
		}
		batch.Logins = append(batch.Logins, sealed)
	}
	_, err := d.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_PublishSealedLogins{PublishSealedLogins: batch}}, nil)
	return err
}

func (d *device) approveJoins(ctx context.Context) error {
	response, err := d.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_PendingJoins{PendingJoins: &pb.Empty{}}}, nil)
	if err != nil {
		return err
	}
	members, err := d.members(ctx)
	if err != nil {
		return err
	}
	var joined []*pb.Machine
	var devices []*pb.Device
	for _, pending := range response.GetPendingJoins().GetJoins() {
		if joining := pending.GetRequest().GetDevice(); joining != nil {
			members.Devices = append(members.Devices, joining)
			devices = append(devices, joining)
			fmt.Printf("Approving device %q (Tailscale node %s).\n", joining.Label, pending.TailscaleNodeName)
		}
		if m := pending.GetRequest().GetMachine(); m != nil {
			m.AutomaticAllowed = true
			members.Machines = append(members.Machines, m)
			joined = append(joined, m)
			fmt.Printf("Approving %q (Tailscale node %s).\n", m.Label, pending.TailscaleNodeName)
		}
	}
	if len(joined) == 0 && len(devices) == 0 {
		return errors.New("nothing is waiting to join")
	}
	members.Revision++
	if err := d.publishMembers(ctx, members); err != nil {
		return err
	}
	for _, m := range joined {
		if err := d.seal(ctx, m.MachineId, m.ReceivingPublicKey, true); err != nil {
			return err
		}
	}
	for _, joining := range devices {
		if err := d.seal(ctx, joining.KeyId, joining.OpeningPublicKey, false); err != nil {
			return err
		}
	}
	return nil
}

// answer waits for the next waiting request and answers it as asked.
func (d *device) answer(ctx context.Context, approve bool, deny string, denyPlain, ignore bool) error {
	var work *pb.Work
	err := d.stream(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_WatchWork{WatchWork: &pb.Empty{}}}, nil, func(response *pb.RelayResponse) bool {
		if w := response.GetWork(); w != nil && w.Outcome == nil {
			work = w
			return false
		}
		return true
	})
	if err != nil {
		return err
	}
	request, err := keyring.ParseRequest(work.Request)
	if err != nil {
		return err
	}
	fmt.Printf("Request %s: %s wants %s: %q\n", request.RequestId[:8], request.Agent, request.LoginId, request.Reason)
	var upload *pb.AnswerUpload
	switch {
	case ignore:
		fmt.Println("Left unanswered.")
		return nil
	case denyPlain:
		upload = &pb.AnswerUpload{DenyRequestId: request.RequestId}
	case deny != "":
		upload, err = keyring.Deny(work.Request, deny, d.self.ReplyKeyId, keyring.SoftwareSigner(d.reply), time.Now())
	case approve:
		members, err := d.members(ctx)
		if err != nil {
			return err
		}
		var asking *pb.Machine
		for _, m := range members.Machines {
			if m.MachineId == request.MachineId {
				asking = m
			}
		}
		if asking == nil || work.SealedLogin == nil {
			return errors.New("cannot approve: unknown machine, or no sealed login for this device")
		}
		secret, err := keyring.OpenLogin(work.SealedLogin, d.opening)
		if err != nil {
			return err
		}
		var sites []string
		for _, login := range catalogueLogins {
			if login.LoginId == secret.LoginId {
				sites = login.Sites
			}
		}
		upload, err = keyring.Approve(work.Request, secret, sites, asking.ReceivingPublicKey, d.self.KeyId, keyring.SoftwareSigner(d.signing), time.Now())
		if err != nil {
			return err
		}
	default:
		return errors.New("choose --approve, --deny WORDS, --deny-plain or --ignore")
	}
	if err != nil {
		return err
	}
	response, err := d.call(ctx, &pb.RelayRequest{Method: &pb.RelayRequest_Answer{Answer: upload}}, nil)
	if err != nil {
		return err
	}
	fmt.Println("Answered:", response.GetLease().GetState())
	return nil
}
