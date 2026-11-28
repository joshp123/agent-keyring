//go:build linux || darwin

// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package clientstate

import "google.golang.org/protobuf/proto"

func (s ClientStateStore) loadPrivateKeys() ([]byte, error) {
	keys := new(PrivateKeys)
	if err := s.readClientStateMessage("keys.pb", keys); err != nil {
		return nil, err
	}
	return proto.Marshal(keys)
}
func (s ClientStateStore) savePrivateKeys(data []byte) error {
	keys := new(PrivateKeys)
	if err := proto.Unmarshal(data, keys); err != nil {
		return err
	}
	return s.writeClientStateMessage("keys.pb", keys)
}
