// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package clientstate

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"slices"
	"time"

	"google.golang.org/protobuf/proto"
)

func operationKey(key string, digest []byte) string {
	if key == "" {
		return hex.EncodeToString(digest)
	}
	return key
}

func operation(state *State, lease, key string, digest []byte) (*OperationReceipt, error) {
	for _, record := range state.Operations {
		if record.LeaseId == lease && record.Key == operationKey(key, digest) {
			if !bytes.Equal(record.Digest, digest) {
				return nil, errors.New("That operation key already names a different action in this lease. Use the original inputs, or inspect the result before using --again.")
			}
			return record, nil
		}
	}
	return nil, nil
}

func pruneOperations(state *State) {
	now := time.Now().Unix()
	state.Operations = slices.DeleteFunc(state.Operations, func(record *OperationReceipt) bool {
		return now >= record.LeaseDeadlineUnixSeconds+24*60*60
	})
}

func (s Store) LookupOperation(ctx context.Context, lease, key string, digest []byte) (*OperationReceipt, error) {
	var record *OperationReceipt
	err := s.Update(ctx, func(state *State) error {
		var err error
		record, err = operation(state, lease, key, digest)
		return err
	})
	return record, err
}

// Returns a previous attempt if another process started it after the lookup.
func (s Store) StartOperation(ctx context.Context, lease, key string, digest []byte, deadline int64) (*OperationReceipt, error) {
	var previous *OperationReceipt
	err := s.Update(ctx, func(state *State) error {
		var err error
		previous, err = operation(state, lease, key, digest)
		if err != nil || previous != nil {
			return err
		}
		if deadline <= time.Now().Unix() {
			return errors.New("This lease has no current delivery deadline. Check its status and request a new lease if the task still needs it.")
		}
		state.Operations = append(state.Operations, &OperationReceipt{LeaseId: lease, Key: operationKey(key, digest), Digest: bytes.Clone(digest), LeaseDeadlineUnixSeconds: deadline})
		return nil
	})
	return previous, err
}

func (s Store) FinishOperation(ctx context.Context, result *OperationReceipt) error {
	return s.Update(ctx, func(state *State) error {
		record, err := operation(state, result.LeaseId, result.Key, result.Digest)
		if err != nil {
			return err
		}
		if record == nil {
			return errors.New("The operation's saved receipt is missing. Inspect its result before repeating it.")
		}
		if record.Outcome != nil {
			return errors.New("The operation already has a saved result.")
		}
		resultCopy := proto.Clone(result).(*OperationReceipt)
		record.Outcome, record.ExitCode = resultCopy.Outcome, resultCopy.ExitCode
		return nil
	})
}
