// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package receiver

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/authority"
)

func GenerateOperationID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(value[:])
}

// Lengths make this encoding unambiguous even when arguments contain separators.
func ComputeOperationDigest(parts ...string) []byte {
	h := sha256.New()
	var length [8]byte
	for _, part := range parts {
		binary.BigEndian.PutUint64(length[:], uint64(len(part)))
		// hash.Hash.Write never returns an error.
		_, _ = h.Write(length[:])
		_, _ = io.WriteString(h, part)
	}
	return h.Sum(nil)
}
func ResolveDeliveryOperationKey(explicit string, again bool) (string, error) {
	if again && explicit != "" {
		return "", errors.New("Use either --again or --operation, not both.")
	}
	if again {
		return GenerateOperationID(), nil
	}
	return explicit, nil
}
func ParseCredentialFieldName(name string) (pb.CredentialField, error) {
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
func ExtractDeliveredValue(values *pb.CredentialValues, field pb.CredentialField) string {
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
func WipeDeliveredValues(values *pb.CredentialValues) {
	if values != nil {
		values.Username = ""
		values.Password = ""
		values.OneTimeCode = ""
	}
}
func ResolveDeliveredCredentialValues(ctx context.Context, client authority.KeyringAuthorityClient, lease *pb.Lease, response *pb.LocalCredentialDelivery, fields []pb.CredentialField) (*pb.CredentialValues, []string, error) {
	if response.GetSealed() != nil {
		if client.OpenValues == nil {
			return nil, nil, errors.New("This local connection returned an unexpected sealed delivery.")
		}
		values, sites, err := client.OpenValues(ctx, lease, response)
		if err != nil {
			return nil, nil, err
		}
		for _, field := range fields {
			if ExtractDeliveredValue(values, field) == "" {
				WipeDeliveredValues(values)
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
	return response.GetValues(), lease.GetAuthorityContext().GetSites(), nil
}

func ReadDeliveredCredential(ctx context.Context, client authority.KeyringAuthorityClient, lease *pb.Lease, field pb.CredentialField, output io.Writer) error {
	response, err := client.DeliverAuthorityCredential(ctx, &pb.DeliverRequest{LeaseId: lease.RequestId, Kind: pb.OperationKind_OPERATION_KIND_READ, Fields: []pb.CredentialField{field}})
	if err != nil {
		return err
	}
	values, _, err := ResolveDeliveredCredentialValues(ctx, client, lease, response, []pb.CredentialField{field})
	if err != nil {
		return err
	}
	defer WipeDeliveredValues(values)
	if _, writeError := io.WriteString(output, ExtractDeliveredValue(values, field)); writeError != nil {
		return errors.New("Could not deliver the value to the receiving process.")
	}
	return nil
}
