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

func Read(ctx context.Context, client authority.Client, lease *pb.Lease, field pb.CredentialField, output io.Writer) error {
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
