// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package receiver

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
)

func NewID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(value[:])
}

func LockOperation(ctx context.Context, scope, target string) (func(), error) {
	return operationLock(ctx, scope, target)
}

func AllowedOrigin(origin string, sites []string) bool { return allowedOrigin(origin, sites) }

// Lengths make this encoding unambiguous even when arguments contain separators.
func Digest(parts ...string) []byte {
	h := sha256.New()
	for _, part := range parts {
		binary.Write(h, binary.BigEndian, uint64(len(part)))
		io.WriteString(h, part)
	}
	return h.Sum(nil)
}
func OperationKey(explicit string, again bool) (string, error) {
	if again && explicit != "" {
		return "", errors.New("Use either --again or --operation, not both.")
	}
	if again {
		return NewID(), nil
	}
	return explicit, nil
}
func Field(name string) (pb.CredentialField, error) {
	switch name {
	case "username":
		return pb.CredentialField_CREDENTIAL_FIELD_USERNAME, nil
	case "password":
		return pb.CredentialField_CREDENTIAL_FIELD_PASSWORD, nil
	case "code", "one-time-code":
		return pb.CredentialField_CREDENTIAL_FIELD_ONE_TIME_CODE, nil
	}
	return 0, errors.New("Choose --field username, password or one-time-code.")
}
func Value(values *pb.CredentialValues, field pb.CredentialField) string {
	switch field {
	case pb.CredentialField_CREDENTIAL_FIELD_USERNAME:
		return values.GetUsername()
	case pb.CredentialField_CREDENTIAL_FIELD_PASSWORD:
		return values.GetPassword()
	case pb.CredentialField_CREDENTIAL_FIELD_ONE_TIME_CODE:
		return values.GetOneTimeCode()
	}
	return ""
}
func ClearValues(values *pb.CredentialValues) {
	if values != nil {
		values.Username = ""
		values.Password = ""
		values.OneTimeCode = ""
	}
}
func Delivered(ctx context.Context, client authority.Client, lease *pb.Lease, response *pb.Delivery, fields []pb.CredentialField) (*pb.CredentialValues, []string, error) {
	if response.GetSealed() != nil {
		if client.OpenValues == nil {
			return nil, nil, errors.New("This local connection returned an unexpected sealed delivery.")
		}
		values, sites, err := client.OpenValues(ctx, lease, response)
		if err != nil {
			return nil, nil, err
		}
		for _, field := range fields {
			if Value(values, field) == "" {
				ClearValues(values)
				return nil, nil, errors.New("The approved delivery has no current value for the requested field.")
			}
		}
		return values, sites, nil
	}
	if client.Remote {
		return nil, nil, errors.New("The relay returned unsealed credentials. No value was used.")
	}
	if response.GetValues() == nil {
		return nil, nil, errors.New("Agent Keyring returned no credential values.")
	}
	return response.GetValues(), lease.Sites, nil
}

func Execute(ctx context.Context, client authority.Client, lease *pb.Lease, field pb.CredentialField, key string) (int, error) {
	if lease.Purpose != pb.Purpose_PURPOSE_PROGRAM || lease.Program == nil {
		return 1, errors.New("This lease does not approve a program. Request a program lease with the command you intend to run.")
	}
	program := lease.Program
	digestParts := []string{lease.LeaseId, "execute-program", program.Executable, fmt.Sprint(field)}
	digestParts = append(digestParts, program.Arguments...)
	digest := Digest(digestParts...)
	unlock, err := operationLock(ctx, "lease", lease.LeaseId)
	if err != nil {
		return 1, err
	}
	defer unlock()
	record, err := client.State.StartOperation(ctx, lease.LeaseId, key, digest, lease.NotAfterUnixSeconds)
	if err != nil {
		return 1, err
	}
	if record != nil {
		if record.GetProgram() == pb.ProgramOutcome_PROGRAM_OUTCOME_EXITED && record.ExitCode != nil {
			return int(*record.ExitCode), nil
		}
		return 1, errors.New("The earlier program attempt may have started. Inspect its result before using --again.")
	}
	response, err := client.Deliver(ctx, &pb.DeliverRequest{LeaseId: lease.LeaseId, Kind: pb.OperationKind_OPERATION_KIND_EXECUTE_PROGRAM, Fields: []pb.CredentialField{field}})
	if err != nil {
		return 1, err
	}
	values, _, err := Delivered(ctx, client, lease, response, []pb.CredentialField{field})
	if err != nil {
		return 1, err
	}
	defer ClearValues(values)
	command := exec.CommandContext(ctx, program.Executable, program.Arguments...)
	command.Stdin = strings.NewReader(Value(values, field))
	command.Stdout = io.Discard
	command.Stderr = io.Discard
	runError := command.Run()
	outcome := pb.ProgramOutcome_PROGRAM_OUTCOME_EXITED
	exitCode := int32(0)
	if runError != nil {
		var exited *exec.ExitError
		if errors.As(runError, &exited) {
			exitCode = int32(exited.ExitCode())
			if exitCode < 0 {
				outcome = pb.ProgramOutcome_PROGRAM_OUTCOME_UNCERTAIN
			}
		} else {
			outcome = pb.ProgramOutcome_PROGRAM_OUTCOME_NOT_STARTED
		}
	}
	finish := &clientstate.OperationReceipt{LeaseId: lease.LeaseId, Key: key, Digest: digest, Outcome: &clientstate.OperationReceipt_Program{Program: outcome}}
	if outcome == pb.ProgramOutcome_PROGRAM_OUTCOME_EXITED {
		finish.ExitCode = &exitCode
	}
	if err = client.State.FinishOperation(context.WithoutCancel(ctx), finish); err != nil {
		return 1, errors.New("The program attempt ended, but its result was not saved. Do not rerun it without inspecting the result.")
	}
	if outcome != pb.ProgramOutcome_PROGRAM_OUTCOME_EXITED {
		return 1, errors.New("The approved program did not exit normally. Inspect its result before repeating it.")
	}
	return int(exitCode), nil
}
func Read(ctx context.Context, client authority.Client, lease *pb.Lease, field pb.CredentialField, output io.Writer) error {
	if lease.Purpose != pb.Purpose_PURPOSE_AGENT_PROCESS {
		return errors.New("This lease does not approve value delivery to the agent's code.")
	}
	key := NewID()
	digest := Digest(lease.LeaseId, "read", fmt.Sprint(field))
	if _, err := client.State.StartOperation(ctx, lease.LeaseId, key, digest, lease.NotAfterUnixSeconds); err != nil {
		return err
	}
	response, err := client.Deliver(ctx, &pb.DeliverRequest{LeaseId: lease.LeaseId, Kind: pb.OperationKind_OPERATION_KIND_READ, Fields: []pb.CredentialField{field}})
	if err != nil {
		return err
	}
	values, _, err := Delivered(ctx, client, lease, response, []pb.CredentialField{field})
	if err != nil {
		return err
	}
	defer ClearValues(values)
	_, writeError := io.WriteString(output, Value(values, field))
	finishError := client.State.FinishOperation(context.WithoutCancel(ctx), &clientstate.OperationReceipt{LeaseId: lease.LeaseId, Key: key, Digest: digest, Outcome: &clientstate.OperationReceipt_ReadDelivered{ReadDelivered: writeError == nil}})
	if writeError != nil {
		return errors.New("Could not deliver the value to the receiving process.")
	}
	if finishError != nil {
		return errors.New("The value was delivered, but its receipt could not be saved.")
	}
	return nil
}
