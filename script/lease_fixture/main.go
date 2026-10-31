// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Dummy authority for system proofs only. Never reads a real vault.
package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/receiver"
	"google.golang.org/protobuf/proto"
)

type fixture struct {
	Origin, Username, Password string
	Seed                       string `json:"totp_secret"`
}
type server struct {
	directory string
	fixture   fixture
	mu        sync.Mutex
}

func main() {
	socket := flag.String("socket", "", "isolated socket")
	config := flag.String("fixture", "", "dummy test_login_server fixture")
	state := flag.String("state", "", "private lease directory")
	flag.Parse()
	if *socket == "" || *config == "" || *state == "" {
		panic("socket, fixture and state are required")
	}
	s := server{directory: *state}
	data, err := os.ReadFile(*config)
	must(err)
	must(json.Unmarshal(data, &s.fixture))
	must(os.MkdirAll(*state, 0700))
	listener, err := net.Listen("unix", *socket)
	must(err)
	must(os.Chmod(*socket, 0600))
	fmt.Println("Dummy authority ready.")
	for {
		conn, err := listener.Accept()
		must(err)
		go s.serve(conn)
	}
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func (s *server) path(name string) string { return filepath.Join(s.directory, name) }
func (s *server) load(name string, message proto.Message) bool {
	data, err := os.ReadFile(s.path(name))
	return err == nil && proto.Unmarshal(data, message) == nil
}
func (s *server) save(name string, message proto.Message) {
	data, err := proto.Marshal(message)
	must(err)
	must(os.WriteFile(s.path(name+".new"), data, 0600))
	must(os.Rename(s.path(name+".new"), s.path(name)))
}
func (s *server) serve(conn net.Conn) {
	defer conn.Close()
	request := new(pb.WireRequest)
	if authority.ReadFrame(conn, request) != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	response := &pb.WireResponse{EndOfStream: true}
	fail := func(text string) {
		response.Response = &pb.WireResponse_Error{Error: &pb.RpcError{Code: pb.RpcErrorCode_RPC_ERROR_CODE_INVALID_ARGUMENT, Message: text}}
	}
	lease := func(id string) *pb.Lease {
		value := new(pb.Lease)
		if !s.load("lease-"+id, value) {
			return nil
		}
		if value.State == 2 && time.Now().Unix() >= value.NotAfterUnixSeconds {
			value.State = 4
			s.save("lease-"+id, value)
		}
		return value
	}
	switch r := request.Request.(type) {
	case *pb.WireRequest_FindLogins:
		response.Response = &pb.WireResponse_Logins{Logins: &pb.FindLoginsResponse{Logins: []*pb.Login{{LoginId: "dummy", Title: "Dummy login", Account: s.fixture.Username, Sites: []string{s.fixture.Origin}, HasOneTimeCode: true, Rule: 2}}}}
	case *pb.WireRequest_RequestLease:
		incoming := r.RequestLease
		var found *pb.Lease
		entries, _ := os.ReadDir(s.directory)
		for _, entry := range entries {
			if len(entry.Name()) < 6 || entry.Name()[:6] != "lease-" {
				continue
			}
			value := new(pb.Lease)
			s.load(entry.Name(), value)
			previous := new(pb.RequestLeaseRequest)
			s.load("request-"+value.LeaseId, previous)
			if previous.RequestId == incoming.RequestId {
				if !proto.Equal(previous, incoming) {
					fail("That request ID was already used for different content.")
					goto done
				}
				found = value
				break
			}
			if value.State == 2 && value.NotAfterUnixSeconds > time.Now().Unix() && value.TaskRef == incoming.TaskRef && value.LoginId == incoming.LoginId && value.Purpose == incoming.Purpose {
				if !proto.Equal(value.Program, incoming.Program) {
					fail("This task already has a different approved command.")
					goto done
				}
				found = value
				break
			}
		}
		if found == nil {
			now := time.Now().Unix()
			found = &pb.Lease{LeaseId: receiver.NewID(), LoginId: incoming.LoginId, TaskRef: incoming.TaskRef, Purpose: incoming.Purpose, State: 2, Reason: incoming.Reason, Program: incoming.Program, Sites: []string{s.fixture.Origin}, ApprovedAtUnixSeconds: now, NotAfterUnixSeconds: now + 1800, ApprovedBy: 1, Recipient: &pb.Recipient{RecipientId: "fixture", MachineLabel: "Dummy machine"}}
			s.save("lease-"+found.LeaseId, found)
			s.save("request-"+found.LeaseId, incoming)
		}
		response.Response = &pb.WireResponse_Lease{Lease: found}
	case *pb.WireRequest_GetLease:
		value := lease(r.GetLease.LeaseId)
		if value == nil {
			fail("No such lease.")
		} else {
			response.Response = &pb.WireResponse_Lease{Lease: value}
		}
	case *pb.WireRequest_WatchLease:
		value := lease(r.WatchLease.LeaseId)
		if value == nil {
			fail("No such lease.")
		} else {
			response.Response = &pb.WireResponse_Lease{Lease: value}
		}
	case *pb.WireRequest_EndLease:
		value := lease(r.EndLease.LeaseId)
		if value == nil {
			fail("No such lease.")
		} else {
			value.State = 5
			s.save("lease-"+value.LeaseId, value)
			response.Response = &pb.WireResponse_Lease{Lease: value}
		}
	case *pb.WireRequest_Deliver:
		b := r.Deliver
		value := lease(b.LeaseId)
		if value == nil {
			fail("No such lease.")
			break
		}
		if value.State != 2 {
			fail("This lease is no longer active.")
			break
		}
		expected := map[pb.OperationKind]pb.Purpose{1: 1, 2: 2, 3: 3}
		if expected[b.Kind] != value.Purpose {
			fail("This lease does not approve that delivery purpose.")
			break
		}
		if len(b.Fields) == 0 {
			fail("Choose a field.")
			break
		}
		values := new(pb.CredentialValues)
		for _, field := range b.Fields {
			switch field {
			case 1:
				values.Username = s.fixture.Username
			case 2:
				values.Password = s.fixture.Password
			case 3:
				seed, _ := base64.StdEncoding.DecodeString(s.fixture.Seed)
				var counter [8]byte
				binary.BigEndian.PutUint64(counter[:], uint64(time.Now().Unix()/30))
				hash := hmac.New(sha1.New, seed)
				hash.Write(counter[:])
				digest := hash.Sum(nil)
				offset := digest[len(digest)-1] & 15
				values.OneTimeCode = fmt.Sprintf("%06d", (binary.BigEndian.Uint32(digest[offset:offset+4])&0x7fffffff)%1000000)
			default:
				fail("Unknown field.")
				goto done
			}
		}
		response.Response = &pb.WireResponse_Delivery{Delivery: &pb.Delivery{Result: &pb.Delivery_Values{Values: values}}}

	default:
		fail("Unsupported fixture method.")
	}
done:
	authority.WriteFrame(conn, response)
}
