// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Package relay is the program on the Mac mini that passes requests and
// answers between machines and devices (proto/agentkeyring/v2/keyring.proto).
// It holds sealed logins and signed documents and can open none of them.
package relay

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
	"google.golang.org/protobuf/proto"
)

// saved is everything the relay keeps, written whole to one private file on
// every change. One person's requests are few, so this stays small.
type saved struct {
	Members   []byte                       `json:"members,omitempty"`   // Signed Members.
	Catalogue []byte                       `json:"catalogue,omitempty"` // Signed Catalogue.
	Sealed    map[string]map[string][]byte `json:"sealed"`              // Opener id, login id: SealedLogin.
	Requests  map[string]*request          `json:"requests"`
	HeldOff   map[string]int64             `json:"held_off"` // Machine id "/" login id: until.
	Pushes    map[string][]byte            `json:"pushes"`   // Device key id: PushRegistration.
	Joins     map[string]*join             `json:"joins"`    // Joiner id.
	Uses      []use                        `json:"uses,omitempty"`
	SelfTests map[string][]byte            `json:"self_tests,omitempty"` // Device key id: Signed SelfTestReport.
}

type request struct {
	Request         []byte        `json:"request"` // Exact Request bytes.
	MachineID       string        `json:"machine_id"`
	ForDevice       string        `json:"for_device,omitempty"` // A device's own test request.
	Proposal        []byte        `json:"proposal,omitempty"`   // Signed RuleProposal.
	ProposedBy      string        `json:"proposed_by,omitempty"`
	ClientRequestID string        `json:"client_request_id,omitempty"`
	State           pb.LeaseState `json:"state"`
	Answer          []byte        `json:"answer,omitempty"` // AnswerUpload, as received.
	AnsweredBy      string        `json:"answered_by,omitempty"`
	AnswerBy        int64         `json:"answer_by"`
	NotAfter        int64         `json:"not_after,omitempty"`
	Reply           string        `json:"reply,omitempty"`
	RetryNotBefore  int64         `json:"retry_not_before,omitempty"`
	Ended           int64         `json:"ended,omitempty"`
}

type join struct {
	Request []byte       `json:"request"` // JoinRequest.
	Node    string       `json:"node"`
	Asked   int64        `json:"asked"`
	State   pb.JoinState `json:"state"`
}

type use struct {
	MachineID string `json:"machine_id"`
	LoginID   string `json:"login_id"`
	Agent     string `json:"agent"`
	Reason    string `json:"reason"`
	At        int64  `json:"at"`
}

// Store keeps the saved state, its parsed documents, and a signal for
// everyone waiting on a change.
type Store struct {
	path      string
	mu        sync.Mutex
	data      saved
	members   *pb.Members
	catalogue *pb.Catalogue
	changed   chan struct{}
}

func OpenStore(directory string) (*Store, error) {
	s := &Store{path: filepath.Join(directory, "relay.json"), changed: make(chan struct{})}
	raw, err := os.ReadFile(s.path)
	switch {
	case errors.Is(err, os.ErrNotExist):
	case err != nil:
		return nil, err
	default:
		if err := json.Unmarshal(raw, &s.data); err != nil {
			return nil, err
		}
	}
	if s.data.Sealed == nil {
		s.data.Sealed = map[string]map[string][]byte{}
	}
	if s.data.Requests == nil {
		s.data.Requests = map[string]*request{}
	}
	if s.data.HeldOff == nil {
		s.data.HeldOff = map[string]int64{}
	}
	if s.data.Pushes == nil {
		s.data.Pushes = map[string][]byte{}
	}
	if s.data.Joins == nil {
		s.data.Joins = map[string]*join{}
	}
	if len(s.data.Members) > 0 {
		signed := &pb.Signed{}
		if err := proto.Unmarshal(s.data.Members, signed); err != nil {
			return nil, err
		}
		s.members = &pb.Members{}
		if err := proto.Unmarshal(signed.Payload, s.members); err != nil {
			return nil, err
		}
	}
	if len(s.data.Catalogue) > 0 {
		signed := &pb.Signed{}
		if err := proto.Unmarshal(s.data.Catalogue, signed); err != nil {
			return nil, err
		}
		s.catalogue = &pb.Catalogue{}
		if err := proto.Unmarshal(signed.Payload, s.catalogue); err != nil {
			return nil, err
		}
	}
	return s, nil
}

// update runs change under the lock, saves, and wakes everyone waiting.
func (s *Store) update(change func(*saved) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := change(&s.data); err != nil {
		return err
	}
	raw, err := json.Marshal(&s.data)
	if err != nil {
		return err
	}
	temporary := s.path + ".new"
	if err := os.WriteFile(temporary, raw, 0o600); err != nil {
		return err
	}
	if err := os.Rename(temporary, s.path); err != nil {
		return err
	}
	close(s.changed)
	s.changed = make(chan struct{})
	return nil
}

// read runs look under the lock and returns a channel closed on the next change.
func (s *Store) read(look func(*saved)) <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	look(&s.data)
	return s.changed
}

// documents returns the current Members and Catalogue, either may be nil.
func (s *Store) documents() (*pb.Members, *pb.Catalogue) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.members, s.catalogue
}

// documentsLocked is documents for code already inside read or update.
func (s *Store) documentsLocked() (*pb.Members, *pb.Catalogue) { return s.members, s.catalogue }

func (s *Store) findLogin(loginID string) *pb.Login {
	_, catalogue := s.documents()
	return loginIn(catalogue, loginID)
}

func loginIn(catalogue *pb.Catalogue, loginID string) *pb.Login {
	if catalogue == nil {
		return nil
	}
	for _, login := range catalogue.Logins {
		if login.LoginId == loginID {
			return login
		}
	}
	return nil
}

func device(members *pb.Members, keyID string) *pb.Device {
	if members == nil {
		return nil
	}
	for _, d := range members.Devices {
		if d.KeyId == keyID {
			return d
		}
	}
	return nil
}

func machine(members *pb.Members, machineID string) *pb.Machine {
	if members == nil {
		return nil
	}
	for _, m := range members.Machines {
		if m.MachineId == machineID {
			return m
		}
	}
	return nil
}

// requestBySHA finds a request by the SHA-256 of its exact bytes.
func requestBySHA(data *saved, sum []byte) (string, *request) {
	for id, r := range data.Requests {
		if string(keyring.SHA256(r.Request)) == string(sum) {
			return id, r
		}
	}
	return "", nil
}
