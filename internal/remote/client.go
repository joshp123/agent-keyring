// Written by AI on 2026.11.18 by model claude opus 5.5; direct, with no relay, on 2026.11.21.
//
// Package remote is the command on a computer without the Mac app: Linux, a
// Mac mini (proto/agentkeyring/v2/keyring.proto, "Direct: no relay"). It
// keeps the command's local interface (agentkeyring.v1 WireRequest) so agents
// see no change. It keeps the lists from the Mac's door, pushes each request
// to Josh's iPhone and Apple Watch itself, takes their answers at this
// computer's own door, and opens what a device approved with this computer's
// own receiving key. Nothing it receives is trusted until checked against the
// Members this computer holds.
package remote

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/door"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"github.com/joshp123/agent-keyring/internal/tlsid"
	"google.golang.org/protobuf/proto"
)

type Client struct {
	Store       clientstate.Store
	Certificate tls.Certificate
	receiving   *ecdh.PrivateKey
	label       string
}

func Load(ctx context.Context, store clientstate.Store) (*Client, error) {
	state, err := store.Load(ctx)
	if err != nil {
		return nil, err
	}
	if state.MacDoor == "" && state.RelayAddress != "" {
		return nil, errors.New("This computer joined through the relay, which Agent Keyring no longer uses. Enrol it again with a link from 'agent-keyring invite' on the Mac.")
	}
	if state.RecipientId == "" || len(state.Members) == 0 || state.MacDoor == "" {
		return nil, errors.New("This computer has not joined. Run 'agent-keyring enrol --name NAME --invite LINK' with a link from 'agent-keyring invite' on the Mac.")
	}
	keys, err := store.Keys(ctx, nil)
	if err != nil {
		return nil, err
	}
	client, err := fromKeys(keys)
	if err != nil {
		return nil, err
	}
	client.Store, client.label = store, state.MachineLabel
	return client, nil
}

func fromKeys(keys *clientstate.PrivateKeys) (*Client, error) {
	certificate, err := tls.X509KeyPair(keys.CertificatePem, keys.TlsKeyPem)
	if err != nil {
		return nil, errors.New("Cannot read this machine's saved TLS identity.")
	}
	receiving, err := ecdh.P256().NewPrivateKey(keys.ReceiverPrivateKey)
	if err != nil {
		return nil, errors.New("Cannot read this machine's saved receiving key.")
	}
	return &Client{Certificate: certificate, receiving: receiving}, nil
}

func (c *Client) Authority() authority.Client {
	return authority.Client{Exchange: c.exchange, OpenValues: c.openValues, Remote: true, State: c.Store}
}

func (c *Client) log(event string) { c.Store.Log(c.label, event) }

// ---- This computer's door ---------------------------------------------------

// One door per process: every request this process runs for shares it.
var theDoor struct {
	once sync.Once
	stop func()
}

// holdDoor starts holding this computer's door for as long as this process
// runs (Close), taking answers for every request of this computer.
func (c *Client) holdDoor() {
	theDoor.once.Do(func() {
		theDoor.stop = door.Hold(context.Background(), c.Certificate, c.doorHandler(), func(address string) {
			c.log("door held address=" + address)
		})
	})
}

// Close lets the door go, after any answer being taken is saved and its
// outcome pushed, so another waiting process can take it over.
func Close() {
	theDoor.once.Do(func() {})
	if theDoor.stop != nil {
		theDoor.stop()
	}
}

// ---- The Mac's door -----------------------------------------------------------

// macClient speaks HTTPS to the Mac's door: this computer's TLS key as the
// client certificate, the Mac's key pinned, and only at a Tailscale address.
func macClient(certificate tls.Certificate, pinned []byte, observed *[]byte) *http.Client {
	config := tlsid.Client(certificate, pinned, observed)
	return &http.Client{Transport: &http.Transport{DialContext: door.Dialer().DialContext, TLSClientConfig: config,
		ForceAttemptHTTP2: true, TLSHandshakeTimeout: 5 * time.Second}}
}

// macDo sends one request to the Mac's door and reads its protobuf reply.
// A refusal comes back as the Mac's own words.
func macDo(ctx context.Context, client *http.Client, method, address, path string, body proto.Message, reply proto.Message) error {
	var reader io.Reader
	if body != nil {
		raw, err := proto.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(raw)
	}
	request, err := http.NewRequestWithContext(ctx, method, "https://"+address+path, reader)
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/octet-stream")
	response, err := client.Do(request)
	if err != nil {
		var urlError *url.Error
		if errors.As(err, &urlError) {
			err = urlError.Err
		}
		return fmt.Errorf("Cannot reach the Mac at %s: %w", address, err)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return fmt.Errorf("The Mac's reply was cut off: %w", err)
	}
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("The Mac refused: %s", printable(strings.TrimSpace(string(raw))))
	}
	if reply != nil && proto.Unmarshal(raw, reply) != nil {
		return errors.New("The Mac's reply is unreadable. Update the Mac app and the command together.")
	}
	return nil
}

func (c *Client) mac(ctx context.Context, method, path string, body, reply proto.Message) error {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return err
	}
	return macDo(ctx, macClient(c.Certificate, state.MacTlsPublicKey, nil), method, state.MacDoor, path, body, reply)
}

// ---- The lists ----------------------------------------------------------------

// view is what this computer holds from the Mac, each part checked.
type view struct {
	members       *pb.Members
	catalogue     *pb.Catalogue
	registrations map[string]*pb.PushRegistration // Device key id: its newest.
	copies        []*pb.SealedLogin
	revisions     *pb.Revisions
	reached       bool // The Mac answered just now.
}

func (v *view) login(loginID string) *pb.Login {
	for _, login := range v.catalogue.GetLogins() {
		if login.LoginId == loginID {
			return login
		}
	}
	return nil
}

func (v *view) device(keyID string) *pb.Device {
	for _, device := range v.members.GetDevices() {
		if device.KeyId == keyID {
			return device
		}
	}
	return nil
}

func (v *view) copyFor(openerID, loginID string) *pb.SealedLogin {
	for _, sealed := range v.copies {
		if sealed.OpenerId == openerID && sealed.LoginId == loginID {
			return sealed
		}
	}
	return nil
}

func parseMembers(raw []byte) (*pb.Members, error) {
	signed := &pb.Signed{}
	members := &pb.Members{}
	if proto.Unmarshal(raw, signed) != nil || proto.Unmarshal(signed.Payload, members) != nil {
		return nil, errors.New("This computer's saved list of devices is unreadable. Enrol it again.")
	}
	return members, nil
}

// held is the view from the saved state alone.
func held(state *clientstate.State) (*view, error) {
	members, err := parseMembers(state.Members)
	if err != nil {
		return nil, err
	}
	v := &view{members: members, registrations: map[string]*pb.PushRegistration{}}
	bundle := &pb.Bundle{}
	if proto.Unmarshal(state.Bundle, bundle) != nil {
		return v, nil
	}
	v.revisions = bundle.Revisions
	if catalogue := (&pb.Catalogue{}); bundle.Catalogue != nil && proto.Unmarshal(bundle.Catalogue.Payload, catalogue) == nil {
		v.catalogue = catalogue
	}
	for _, signed := range bundle.PushRegistrations {
		registration := &pb.PushRegistration{}
		if proto.Unmarshal(signed.Payload, registration) == nil {
			v.registrations[registration.DeviceKeyId] = registration
		}
	}
	v.copies = bundle.Copies
	return v, nil
}

// refresh asks the Mac for its revisions, within limit, and fetches and
// checks its bundle if it has newer lists. If the Mac does not answer in
// time it returns what this computer holds, with reached false.
func (c *Client) refresh(ctx context.Context, limit time.Duration) (*view, error) {
	state, err := c.Store.Load(ctx)
	if err != nil {
		return nil, err
	}
	current, err := held(state)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, limit)
	defer cancel()
	revisions := &pb.Revisions{}
	if err := c.mac(ctx, http.MethodGet, "/v2/rev", nil, revisions); err != nil {
		c.log("mac unreachable error=" + strconv.Quote(err.Error()))
		return current, nil
	}
	have := current.revisions
	if have != nil && revisions.Members <= have.Members && revisions.Catalogue <= have.Catalogue && revisions.Copies <= have.Copies &&
		revisions.Members <= current.members.Revision {
		current.reached = true
		return current, nil
	}
	bundle := &pb.Bundle{}
	if err := c.mac(ctx, http.MethodGet, "/v2/bundle?members="+strconv.FormatUint(current.members.Revision, 10), nil, bundle); err != nil {
		c.log("bundle not fetched error=" + strconv.Quote(err.Error()))
		return current, nil
	}
	if err := c.keepBundle(ctx, bundle); err != nil {
		return nil, err
	}
	state, err = c.Store.Load(ctx)
	if err != nil {
		return nil, err
	}
	if current, err = held(state); err != nil {
		return nil, err
	}
	current.reached = true
	return current, nil
}

// keepBundle checks each part of a bundle on its own and saves the parts that
// check: the lists by their signatures and revisions, each copy by its signer
// and the catalogue's version. A part that does not check keeps what this
// computer held.
func (c *Client) keepBundle(ctx context.Context, bundle *pb.Bundle) error {
	return c.Store.Update(ctx, func(state *clientstate.State) error {
		members, err := parseMembers(state.Members)
		if err != nil {
			return err
		}
		old := &pb.Bundle{}
		proto.Unmarshal(state.Bundle, old)
		kept := &pb.Bundle{Revisions: bundle.Revisions, Catalogue: old.Catalogue}
		// Each revision since the one held is checked against the one before
		// it, so a list signed by a device added since still checks.
		for _, document := range append(bundle.MembersSince, bundle.Members) {
			if document == nil {
				continue
			}
			next, err := keyring.VerifiedMembers(document, members)
			if errors.Is(err, keyring.ErrStale) {
				continue
			}
			if err != nil {
				c.log("members refused error=" + strconv.Quote(err.Error()))
				break
			}
			members = next
			state.Members, _ = proto.Marshal(document)
			c.log(fmt.Sprintf("members taken revision=%d", next.Revision))
		}
		catalogue := &pb.Catalogue{}
		if old.Catalogue != nil {
			proto.Unmarshal(old.Catalogue.Payload, catalogue)
		}
		if bundle.Catalogue != nil {
			if next, err := keyring.VerifiedCatalogue(bundle.Catalogue, members, nil); err != nil {
				c.log("catalogue refused error=" + strconv.Quote(err.Error()))
			} else if next.Revision < state.CatalogueRevision {
				c.log(fmt.Sprintf("catalogue refused revision=%d held=%d", next.Revision, state.CatalogueRevision))
			} else {
				catalogue, kept.Catalogue, state.CatalogueRevision = next, bundle.Catalogue, next.Revision
			}
		}
		listed := map[string]*pb.Login{}
		for _, login := range catalogue.Logins {
			listed[login.LoginId] = login
		}
		newest := map[string]*pb.Signed{}
		registered := map[string]int64{}
		for _, signed := range bundle.PushRegistrations {
			registration, err := checkRegistration(signed, members)
			if err != nil {
				c.log("push registration refused error=" + strconv.Quote(err.Error()))
				continue
			}
			if registration.RegisteredUnixSeconds >= registered[registration.DeviceKeyId] {
				newest[registration.DeviceKeyId], registered[registration.DeviceKeyId] = signed, registration.RegisteredUnixSeconds
			}
		}
		for _, signed := range newest {
			kept.PushRegistrations = append(kept.PushRegistrations, signed)
		}
		for _, sealed := range bundle.Copies {
			opener := sealed.OpenerId == state.RecipientId
			for _, device := range members.Devices {
				opener = opener || (device.KeyId == sealed.OpenerId && device.Kind == pb.DeviceKind_DEVICE_KIND_WATCH)
			}
			if !opener || keyring.CheckSealed(sealed, members, listed[sealed.LoginId]) != nil {
				c.log("copy refused login=" + sealed.LoginId)
				continue
			}
			kept.Copies = append(kept.Copies, sealed)
		}
		state.Bundle, _ = proto.Marshal(kept)
		return nil
	})
}

// checkRegistration accepts a push registration signed by the reply key of
// the device it names, or for an Apple Watch by its iPhone's.
func checkRegistration(signed *pb.Signed, members *pb.Members) (*pb.PushRegistration, error) {
	registration := &pb.PushRegistration{}
	if proto.Unmarshal(signed.GetPayload(), registration) != nil || registration.Domain != keyring.PushDomain {
		return nil, keyring.ErrWrongDomain
	}
	signer, err := keyring.Verify(signed, members, true)
	if err != nil {
		return nil, err
	}
	if signed.SignerKeyId != signer.ReplyKeyId {
		return nil, keyring.ErrNotAllowed
	}
	for _, device := range members.Devices {
		if device.KeyId == registration.DeviceKeyId &&
			(device.KeyId == signer.KeyId || (device.Kind == pb.DeviceKind_DEVICE_KIND_WATCH && signer.Kind == pb.DeviceKind_DEVICE_KIND_IPHONE)) {
			return registration, nil
		}
	}
	return nil, keyring.ErrNotAllowed
}

// ---- Logs ---------------------------------------------------------------------

// Logs is this computer's own lines, with the Mac's and the devices' if the
// Mac's door answers, in time order.
func (c *Client) Logs(ctx context.Context, since int64, requestID string) ([]string, error) {
	lines := c.Store.LogLines()
	mac := &pb.Logs{}
	macCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := c.mac(macCtx, http.MethodGet, "/v2/logs?since="+strconv.FormatInt(since, 10), nil, mac); err == nil {
		lines = append(lines, mac.Lines...)
	}
	var kept []string
	cutoff := time.Unix(since, 0).UTC().Format("2006-01-02T15:04:05.000Z")
	for _, line := range lines {
		if line == "" || (since > 0 && line < cutoff) || (requestID != "" && !strings.Contains(line, requestID)) {
			continue
		}
		kept = append(kept, line)
	}
	sortLines(kept)
	return kept, nil
}

func sortLines(lines []string) {
	for i := 1; i < len(lines); i++ {
		for j := i; j > 0 && lines[j] < lines[j-1]; j-- {
			lines[j], lines[j-1] = lines[j-1], lines[j]
		}
	}
}

// printable replaces control characters, so words from a device cannot
// rewrite the agent's terminal.
func printable(value string) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return ' '
		}
		return r
	}, value)
}
