// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Full-system proof: a separate process calls the production Swift authority
// over its Unix socket and kills/restarts it. Only the built-in login is used.
package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"google.golang.org/protobuf/proto"
)

var socket string
var authority string
var root string
var cli string
var child *exec.Cmd
var control io.WriteCloser
var output *bufio.Scanner

func check(ok bool, text string) {
	if !ok {
		panic(text)
	}
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func start() {
	child = exec.Command(authority, root)
	var err error
	control, err = child.StdinPipe()
	must(err)
	out, err := child.StdoutPipe()
	must(err)
	child.Stderr = os.Stderr
	output = bufio.NewScanner(out)
	must(child.Start())
	check(output.Scan() && bytes.HasPrefix(output.Bytes(), []byte("Ready:")), "authority did not start")
}
func stop() { must(child.Process.Kill()); _ = child.Wait() }
func owner(action string) {
	_, err := fmt.Fprintln(control, action)
	must(err)
	check(output.Scan() && output.Text() == "Owner action committed", "owner action failed")
}
func send(c net.Conn, request *pb.WireRequest) {
	data, err := proto.Marshal(request)
	must(err)
	must(binary.Write(c, binary.BigEndian, uint32(len(data))))
	_, err = c.Write(data)
	must(err)
}
func receive(c net.Conn) *pb.WireResponse {
	_ = c.SetReadDeadline(time.Now().Add(8 * time.Second))
	var size uint32
	must(binary.Read(c, binary.BigEndian, &size))
	check(size > 0 && size <= 1048576, "invalid response frame")
	data := make([]byte, size)
	_, err := io.ReadFull(c, data)
	must(err)
	result := &pb.WireResponse{}
	must(proto.Unmarshal(data, result))
	return result
}
func rpc(request *pb.WireRequest) *pb.WireResponse {
	c, err := net.Dial("unix", socket)
	must(err)
	defer c.Close()
	send(c, request)
	result := receive(c)
	check(result.EndOfStream, "unary response must end stream")
	return result
}
func lease(task, id string, purpose pb.Purpose) *pb.Lease {
	request := &pb.RequestLeaseRequest{LoginId: "00000000-0000-0000-0000-000000000301", TaskRef: task, RequestId: id, Purpose: purpose, Reason: "Exercise the example login"}
	if purpose == pb.Purpose_PURPOSE_PROGRAM {
		request.Program = &pb.ProgramCommand{Executable: "/usr/bin/true"}
	}
	result := rpc(&pb.WireRequest{Request: &pb.WireRequest_RequestLease{RequestLease: request}})
	check(result.GetLease() != nil, fmt.Sprintf("request failed: %v", result.GetError()))
	return result.GetLease()
}
func get(id string) *pb.Lease {
	r := rpc(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: id}}})
	check(r.GetLease() != nil, "get failed")
	return r.GetLease()
}
func end(id string) *pb.Lease {
	return rpc(&pb.WireRequest{Request: &pb.WireRequest_EndLease{EndLease: &pb.LeaseReference{LeaseId: id}}}).GetLease()
}
func deliver(id string, kind pb.OperationKind, fields ...pb.CredentialField) *pb.WireResponse {
	return rpc(&pb.WireRequest{Request: &pb.WireRequest_Deliver{Deliver: &pb.DeliverRequest{LeaseId: id, Kind: kind, Fields: fields}}})
}
func main() {
	flag.StringVar(&authority, "authority", "", "Swift authority fixture executable")
	flag.StringVar(&root, "root", "", "isolated persistent directory")
	flag.StringVar(&cli, "cli", "", "optional real Go CLI executable")
	flag.Parse()
	check(authority != "" && root != "", "supply --authority and --root")
	socket = filepath.Join(root, "agent.sock")
	start()
	defer func() {
		if child != nil && child.ProcessState == nil {
			stop()
		}
	}()
	found := rpc(&pb.WireRequest{Request: &pb.WireRequest_FindLogins{FindLogins: &pb.FindLoginsRequest{Query: "example.com"}}})
	check(len(found.GetLogins().GetLogins()) == 1, "find example login")
	active := lease("automatic", "request-1", pb.Purpose_PURPOSE_AGENT_PROCESS)
	check(active.State == pb.LeaseState_LEASE_STATE_ACTIVE && active.NotAfterUnixSeconds-active.ApprovedAtUnixSeconds == 1800, "Automatic deadline")
	check(active.RequestedAtUnixSeconds > 0 && active.EndedAtUnixSeconds == 0, "request time recorded")
	earlierSlots := readSlots()
	joined := lease("automatic", "request-2", pb.Purpose_PURPOSE_AGENT_PROCESS)
	check(proto.Equal(active, joined), "concurrent task scope joins original record")
	conflict := rpc(&pb.WireRequest{Request: &pb.WireRequest_RequestLease{RequestLease: &pb.RequestLeaseRequest{LoginId: active.LoginId, TaskRef: "changed", RequestId: "request-1", Purpose: active.Purpose, Reason: active.Reason}}})
	check(conflict.GetError().GetCode() == pb.RpcErrorCode_RPC_ERROR_CODE_CONFLICT, "request conflict")
	missing := deliver(active.LeaseId, pb.OperationKind_OPERATION_KIND_READ, pb.CredentialField_CREDENTIAL_FIELD_ONE_TIME_CODE)
	check(missing.GetError() != nil, "unavailable field refused")
	delivered := deliver(active.LeaseId, pb.OperationKind_OPERATION_KIND_READ, pb.CredentialField_CREDENTIAL_FIELD_PASSWORD).GetDelivery()
	check(delivered.GetValues().GetPassword() == "example-password", "read values privately consumed")
	stop()
	start()
	check(proto.Equal(active, get(active.LeaseId)), "restart preserves lease and original deadline")
	repeated := deliver(active.LeaseId, pb.OperationKind_OPERATION_KIND_READ, pb.CredentialField_CREDENTIAL_FIELD_PASSWORD).GetDelivery()
	check(proto.Equal(delivered, repeated), "delivery remains available under the same lease after restart")
	if cli != "" {
		proveCLI()
	}
	fmt.Println("PASS Automatic, joining, conflicts, unavailable fields, restart and Deliver")
	for _, purpose := range []pb.Purpose{pb.Purpose_PURPOSE_BROWSER_SIGN_IN, pb.Purpose_PURPOSE_PROGRAM} {
		item := lease(fmt.Sprintf("purpose-%d", purpose), fmt.Sprintf("purpose-request-%d", purpose), purpose)
		kind := pb.OperationKind_OPERATION_KIND_FILL
		if purpose == pb.Purpose_PURPOSE_PROGRAM {
			kind = pb.OperationKind_OPERATION_KIND_EXECUTE_PROGRAM
		}
		result := deliver(item.LeaseId, kind, pb.CredentialField_CREDENTIAL_FIELD_PASSWORD).GetDelivery()
		check(result.GetValues() != nil, "purpose operation returns requested fields")
		check(result.GetValues().Username == "" && result.GetValues().OneTimeCode == "", "only requested fields")
		end(item.LeaseId)
		check(deliver(item.LeaseId, kind, pb.CredentialField_CREDENTIAL_FIELD_PASSWORD).GetError() != nil, "delivery after release refused")
	}
	wrong := deliver(active.LeaseId, pb.OperationKind_OPERATION_KIND_FILL, pb.CredentialField_CREDENTIAL_FIELD_USERNAME)
	check(wrong.GetError() != nil, "wrong purpose refused")
	owner("ask")
	check(get(active.LeaseId).State == pb.LeaseState_LEASE_STATE_REVOKED, "Automatic to Ask revokes")
	pending := lease("ask", "ask-1", pb.Purpose_PURPOSE_BROWSER_SIGN_IN)
	check(pending.State == pb.LeaseState_LEASE_STATE_PENDING, "Ask pending")
	stop()
	start()
	check(proto.Equal(pending, get(pending.LeaseId)), "pending restart deadline fixed")
	owner("cancel-approval " + pending.LeaseId)
	check(get(pending.LeaseId).State == pb.LeaseState_LEASE_STATE_PENDING, "cancelled panel evaluation leaves pending")
	owner("failed-approval " + pending.LeaseId)
	check(get(pending.LeaseId).State == pb.LeaseState_LEASE_STATE_PENDING, "failed biometric leaves pending")
	c, err := net.Dial("unix", socket)
	must(err)
	send(c, &pb.WireRequest{Request: &pb.WireRequest_WatchLease{WatchLease: &pb.LeaseReference{LeaseId: pending.LeaseId}}})
	check(receive(c).GetLease().State == pb.LeaseState_LEASE_STATE_PENDING, "watch initial snapshot")
	owner("deny " + pending.LeaseId + " Use the other account")
	update := receive(c)
	c.Close()
	check(update.EndOfStream && update.GetLease().State == pb.LeaseState_LEASE_STATE_DENIED, "watch terminal update")
	check(update.GetLease().EndedAtUnixSeconds >= pending.RequestedAtUnixSeconds, "denial time recorded")
	stop()
	start()
	denied := lease("different-task", "denial-2", pb.Purpose_PURPOSE_AGENT_PROCESS)
	check(denied.State == pb.LeaseState_LEASE_STATE_DENIED && denied.Reply == "Use the other account" && denied.RetryNotBeforeUnixSeconds == get(pending.LeaseId).RetryNotBeforeUnixSeconds, "denial persists across task and purpose")
	owner("clear-denial")
	check(get(pending.LeaseId).RetryNotBeforeUnixSeconds == 0 && get(denied.LeaseId).RetryNotBeforeUnixSeconds == 0, "clear denial updates every denied history row")
	cancelled := lease("cancel", "cancel-1", pb.Purpose_PURPOSE_AGENT_PROCESS)
	check(end(cancelled.LeaseId).State == pb.LeaseState_LEASE_STATE_CANCELLED, "cancel pending")
	check(lease("cancel", "cancel-1", pb.Purpose_PURPOSE_AGENT_PROCESS).State == pb.LeaseState_LEASE_STATE_CANCELLED, "terminal exact retry stays terminal")
	owner("auto")
	ownerEnded := lease("owner-revocation", "owner-end", pb.Purpose_PURPOSE_BROWSER_SIGN_IN)
	owner("revoke " + ownerEnded.LeaseId)
	ownerEnded = get(ownerEnded.LeaseId)
	check(ownerEnded.State == pb.LeaseState_LEASE_STATE_REVOKED && ownerEnded.EndedAtUnixSeconds > 0, "owner ending access is revoked with an end time")
	stop()
	start()
	check(proto.Equal(ownerEnded, get(ownerEnded.LeaseId)), "revocation and history survive restart")
	blocked := lease("blocked", "block-1", pb.Purpose_PURPOSE_BROWSER_SIGN_IN)
	owner("block")
	check(get(blocked.LeaseId).State == pb.LeaseState_LEASE_STATE_REVOKED, "Blocked revokes")
	check(lease("blocked-new", "block-2", pb.Purpose_PURPOSE_BROWSER_SIGN_IN).State == pb.LeaseState_LEASE_STATE_DENIED, "Blocked refuses fresh requests")
	fmt.Println("PASS delivery purposes, release refusal, rule revocation, Ask restart, Watch, denial suppression and cancellation")
	unknown := &pb.WireRequest{}
	unknown.ProtoReflect().SetUnknown([]byte{0x58, 1})
	for _, r := range []*pb.WireRequest{unknown, {Request: &pb.WireRequest_Fill{Fill: &pb.FillRequest{}}}, {Request: &pb.WireRequest_ExecuteProgram{ExecuteProgram: &pb.ExecuteProgramRequest{}}}} {
		check(rpc(r).GetError() != nil, "non-authority method refused")
	}
	c, err = net.Dial("unix", socket)
	must(err)
	old := []byte(`{"version":1,"action":"acquire"}`)
	must(binary.Write(c, binary.BigEndian, uint32(len(old))))
	_, err = c.Write(old)
	must(err)
	var size uint32
	must(binary.Read(c, binary.BigEndian, &size))
	data := make([]byte, size)
	_, err = io.ReadFull(c, data)
	must(err)
	c.Close()
	check(bytes.Contains(data, []byte("agent-keyring lease")), "old JSON client migration error")
	for _, data := range [][]byte{{0, 0, 0, 0}, {0, 16, 0, 1}, {0, 0, 0, 1, 255}} {
		c, err = net.Dial("unix", socket)
		must(err)
		_, err = c.Write(data)
		must(err)
		_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
		var b [1]byte
		_, err = c.Read(b[:])
		check(err != nil, "bad frame closed")
		c.Close()
	}
	fmt.Println("PASS every authority method, receiver-method rejection, JSON migration, malformed frames")
	stop()
	committedSlots := readSlots()
	writeSlots(earlierSlots)
	rejectDiskState("older valid authority snapshots must not roll back the checkpoint")
	writeSlots(committedSlots)
	start()
	check(get(active.LeaseId).State == pb.LeaseState_LEASE_STATE_REVOKED, "original checkpoint restores its committed lease history")
	stop()
	for i := 0; i < 2; i++ {
		must(os.WriteFile(filepath.Join(root, "leases", fmt.Sprintf("authority-%d.plist", i)), []byte("untrusted changed authority"), 0600))
	}
	rejectDiskState("tampered disk state must not activate")
	fmt.Println("PASS modified and rolled-back disk authority rejected without resetting leases")
}

func readSlots() [2][]byte {
	var result [2][]byte
	for i := range result {
		result[i], _ = os.ReadFile(filepath.Join(root, "leases", fmt.Sprintf("authority-%d.plist", i)))
	}
	return result
}
func writeSlots(slots [2][]byte) {
	for i, data := range slots {
		must(os.WriteFile(filepath.Join(root, "leases", fmt.Sprintf("authority-%d.plist", i)), data, 0600))
	}
}
func rejectDiskState(message string) {
	start()
	// Recovery keeps discovery available while all task access is stopped.
	found := rpc(&pb.WireRequest{Request: &pb.WireRequest_FindLogins{FindLogins: &pb.FindLoginsRequest{Query: "example.com"}}})
	check(len(found.GetLogins().GetLogins()) == 1, "history recovery preserves login discovery")
	request := &pb.RequestLeaseRequest{LoginId: "00000000-0000-0000-0000-000000000301", TaskRef: "untrusted-history", RequestId: "untrusted-history", Purpose: pb.Purpose_PURPOSE_AGENT_PROCESS, Reason: "Check history recovery refuses access"}
	refused := rpc(&pb.WireRequest{Request: &pb.WireRequest_RequestLease{RequestLease: request}})
	check(refused.GetError().GetCode() == pb.RpcErrorCode_RPC_ERROR_CODE_UNAVAILABLE, message)
	check(bytes.Contains([]byte(refused.GetError().GetMessage()), []byte("Reset task history")), "history recovery names the owner action")
	stop()
}
func proveCLI() {
	run := func(args ...string) []byte {
		command := exec.Command(cli, args...)
		command.Env = append(os.Environ(), "AGENT_KEYRING_SOCKET="+socket, "AGENT_KEYRING_STATE_DIR="+filepath.Join(root, "client-state"))
		var diagnostics bytes.Buffer
		command.Stderr = &diagnostics
		out, err := command.Output()
		check(err == nil, "real CLI command failed: "+args[0]+" "+diagnostics.String())
		check(!bytes.Contains(diagnostics.Bytes(), []byte("example-password")), "CLI diagnostics exposed fixture")
		return out
	}
	id := string(bytes.TrimSpace(run("lease", "00000000-0000-0000-0000-000000000301", "--task", "cli-read", "--reason", "Private system proof", "--for", "agent-process")))
	check(id != "" && bytes.Equal(bytes.TrimSpace(run("read", id, "--field", "password")), []byte("example-password")), "real CLI private consumer")
	run("status", id, "--wait")
	run("release", id)
	program := string(bytes.TrimSpace(run("lease", "00000000-0000-0000-0000-000000000301", "--task", "cli-program", "--reason", "System proof of suppressed child output", "--for", "program", "--", "/usr/bin/tee")))
	check(len(run("exec", program, "--field", "password")) == 0, "real CLI child output suppressed")
	stop()
	start()
	check(len(run("exec", program, "--field", "password")) == 0, "real CLI program receipt survives authority restart")
	run("release", program)
	fmt.Println("PASS real Go CLI with Swift authority: private read, program stdout suppression, receipt after restart, release")
}
