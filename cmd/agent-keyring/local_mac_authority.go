// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Commands that go to the Mac app over its agent socket: the push key, and an
// agent's complaints when the command runs inside the app's bundle. On a
// computer without the app, complain and complaints keep them in this
// computer's own state instead (complaint_commands.go).
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
)

// runMacAuthorityCommand runs push-key, complain and complaints; handled is false for any other command.
func runMacAuthorityCommand(ctx context.Context, command string, a cliArguments) (int, bool, error) {
	switch command {
	case "push-key":
		code, err := pushKeyOnMac(ctx, a)
		return code, true, err
	case "complain", "complaints":
		if contentsPath() != "" {
			code, err := complaintsOnMac(ctx, command, a)
			return code, true, err
		}
	}
	return 0, false, nil
}

func pushKeyOnMac(ctx context.Context, a cliArguments) (int, error) {
	if err := a.checkCommandOptions("key-id team-id", ""); err != nil || len(a.positionals) > 0 || a.options["key-id"] == "" || a.options["team-id"] == "" {
		return 2, errors.New("push-key takes --key-id ID --team-id ID, with Apple's .p8 file on standard input.")
	}
	key, e := readPushKey(os.Stdin)
	if e != nil {
		return 2, e
	}
	request := &pb.AgentRequest{Request: &pb.AgentRequest_PushKey{PushKey: &pb.PushKeyRequest{
		KeyId: a.options["key-id"], TeamId: a.options["team-id"], PrivateKey: key}}}
	if _, e = callMac(ctx, request); e != nil {
		return 1, e
	}
	fmt.Fprintln(os.Stderr, "Agent Keyring keeps the push key in its keychain; it sends pushes with it and gives it to each computer that joins.")
	return 0, nil
}

func complaintsOnMac(ctx context.Context, command string, a cliArguments) (int, error) {
	if complaints != "on" {
		return 1, errors.New("Complaints are off in this build of Agent Keyring.")
	}
	if command == "complain" {
		if err := a.checkCommandOptions("summary command thread", ""); err != nil || len(a.positionals) > 0 || strings.TrimSpace(a.options["summary"]) == "" {
			return 2, errors.New("complain takes --summary LINE, and --command TEXT and --thread ID if you have them; anything more on standard input. Never a password or secret.")
		}
		complaint := &pb.Complaint{AtUnixSeconds: time.Now().Unix(), Command: a.options["command"], Thread: a.options["thread"],
			Summary: a.options["summary"], Detail: readDetail()}
		if _, e := callMac(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_Complain{Complain: &pb.ComplainRequest{Complaint: complaint}}}); e != nil {
			return 1, e
		}
		fmt.Fprintln(os.Stderr, "Kept on the Mac. Thank you.")
		return 0, nil
	}
	if err := a.checkCommandOptions("since", ""); err != nil || len(a.positionals) > 0 {
		return 2, errors.New("complaints takes --since DURATION (such as 24h), optional.")
	}
	var since int64
	if text := a.options["since"]; text != "" {
		duration, e := time.ParseDuration(text)
		if e != nil || duration <= 0 {
			return 2, errors.New("--since takes a duration such as 30m or 24h.")
		}
		since = time.Now().Add(-duration).Unix()
	}
	response, e := callMac(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_Complaints{Complaints: &pb.ComplaintsRequest{SinceUnixSeconds: since}}})
	if e != nil {
		return 1, e
	}
	for _, c := range response.GetComplaints().GetComplaints() {
		fmt.Printf("%s %s %s: %s\n", time.Unix(c.AtUnixSeconds, 0).UTC().Format(time.RFC3339), sanitizeTerminalText(c.Computer), sanitizeTerminalText(c.Command), sanitizeTerminalText(c.Summary))
		if c.Detail != "" {
			fmt.Println(sanitizeTerminalText(c.Detail))
		}
	}
	return 0, nil
}

func callMac(ctx context.Context, request *pb.AgentRequest) (*pb.AgentResponse, error) {
	local, err := localSetupAuthority(ctx)
	if err != nil {
		return nil, err
	}
	return local.CallKeyringAuthority(ctx, request)
}

// readPushKey takes Apple's .p8 file (PKCS#8 PEM) and returns its DER, refusing anything but a P-256 key.
func readPushKey(input io.Reader) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(input, 1<<16))
	if err != nil {
		return nil, err
	}
	defer clear(data)
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" {
		return nil, errors.New("Give Apple's .p8 file on standard input: agent-keyring push-key --key-id ID --team-id ID < AuthKey_ID.p8")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if key, ok := parsed.(*ecdsa.PrivateKey); err != nil || !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("That is not a P-256 push key from Apple.")
	}
	return block.Bytes, nil
}

// readDetail is anything piped in, never a terminal's typing.
func readDetail() string {
	if info, err := os.Stdin.Stat(); err != nil || info.Mode()&os.ModeCharDevice != 0 {
		return ""
	}
	data, _ := io.ReadAll(io.LimitReader(os.Stdin, 64<<10))
	return string(data)
}
