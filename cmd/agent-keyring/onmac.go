// Written by AI on 2026.11.21 by model claude opus 5.5.
//
// Commands that go to the Mac app over its agent socket: the push key, and an
// agent's complaints when the command runs inside the app's bundle. On a
// computer without the app, complain and complaints go through the Mac's door
// instead (onDoor, the Go engineer's).
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

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
)

// onMac runs push-key, complain and complaints; handled is false for any other command.
func onMac(ctx context.Context, command string, a arguments) (code int, handled bool, err error) {
	switch command {
	case "push-key":
		if err = a.check("key-id team-id", ""); err != nil || len(a.positionals) > 0 || a.options["key-id"] == "" || a.options["team-id"] == "" {
			return 2, true, errors.New("push-key takes --key-id ID --team-id ID, with Apple's .p8 file on standard input.")
		}
		key, e := readPushKey(os.Stdin)
		if e != nil {
			return 2, true, e
		}
		request := &pb.WireRequest{Request: &pb.WireRequest_PushKey{PushKey: &pb.PushKeyRequest{
			KeyId: a.options["key-id"], TeamId: a.options["team-id"], PrivateKey: key}}}
		if _, e = callMac(ctx, request); e != nil {
			return 1, true, e
		}
		fmt.Fprintln(os.Stderr, "Agent Keyring keeps the push key in its keychain; it sends pushes with it and gives it to each computer that joins.")
		return 0, true, nil
	case "complain", "complaints":
		if contentsPath() == "" {
			return 0, false, nil // Not the app's own command: the door path handles it.
		}
		if command == "complain" {
			if err = a.check("summary command thread", ""); err != nil || len(a.positionals) > 0 || strings.TrimSpace(a.options["summary"]) == "" {
				return 2, true, errors.New("complain takes --summary LINE, and --command TEXT and --thread ID if you have them; anything more on standard input. Never a password or secret.")
			}
			complaint := &pb.Complaint{AtUnixSeconds: time.Now().Unix(), Command: a.options["command"], Thread: a.options["thread"],
				Summary: a.options["summary"], Detail: readDetail()}
			if _, e := callMac(ctx, &pb.WireRequest{Request: &pb.WireRequest_Complain{Complain: &pb.ComplainRequest{Complaint: complaint}}}); e != nil {
				return 1, true, e
			}
			fmt.Fprintln(os.Stderr, "Kept on the Mac. Thank you.")
			return 0, true, nil
		}
		if err = a.check("since", ""); err != nil || len(a.positionals) > 0 {
			return 2, true, errors.New("complaints takes --since DURATION (such as 24h), optional.")
		}
		var since int64
		if text := a.options["since"]; text != "" {
			duration, e := time.ParseDuration(text)
			if e != nil || duration <= 0 {
				return 2, true, errors.New("--since takes a duration such as 30m or 24h.")
			}
			since = time.Now().Add(-duration).Unix()
		}
		response, e := callMac(ctx, &pb.WireRequest{Request: &pb.WireRequest_Complaints{Complaints: &pb.ComplaintsRequest{SinceUnixSeconds: since}}})
		if e != nil {
			return 1, true, e
		}
		for _, c := range response.GetComplaints().GetComplaints() {
			fmt.Printf("%s %s %s: %s\n", time.Unix(c.AtUnixSeconds, 0).UTC().Format(time.RFC3339), safe(c.Computer), safe(c.Command), safe(c.Summary))
			if c.Detail != "" {
				fmt.Println(safe(c.Detail))
			}
		}
		return 0, true, nil
	}
	return 0, false, nil
}

func callMac(ctx context.Context, request *pb.WireRequest) (*pb.WireResponse, error) {
	local, err := localSetupAuthority(ctx)
	if err != nil {
		return nil, err
	}
	return local.Call(ctx, request)
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
