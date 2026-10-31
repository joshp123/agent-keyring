// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relaycrypto

import (
	"encoding/binary"
	"encoding/hex"
)

const CopyLoginInfo = "agentkeyring.login-copy.v1"

func CopyDestinationID(encryptionPublicKey []byte) string {
	return hex.EncodeToString(Hash(encryptionPublicKey))
}

// CopyLoginAAD is reproduced directly in Swift: UTF-8 byte lengths and unsigned
// integers are big-endian. The signed update covers the entire sealed envelope.
func CopyLoginAAD(destination string, configurationRevision, updateRevision uint64, loginID string) []byte {
	data := binary.BigEndian.AppendUint32(nil, uint32(len([]byte(destination))))
	data = append(data, []byte(destination)...)
	data = binary.BigEndian.AppendUint64(data, configurationRevision)
	data = binary.BigEndian.AppendUint64(data, updateRevision)
	return append(data, []byte(loginID)...)
}
