// Written by AI on 2026.11.18 by model claude opus 5.5.
// Package wire frames protobuf messages for the relay: a 4-byte big-endian
// length, then the message, 4 MiB at most (keyring.proto, "Wire").
package wire

import (
	"encoding/binary"
	"errors"
	"io"

	"google.golang.org/protobuf/proto"
)

const MaxFrame = 4 << 20

func Write(w io.Writer, message proto.Message) error {
	data, err := proto.Marshal(message)
	if err != nil {
		return err
	}
	if len(data) > MaxFrame {
		return errors.New("message too large")
	}
	_, err = w.Write(append(binary.BigEndian.AppendUint32(nil, uint32(len(data))), data...))
	return err
}

func Read(r io.Reader, message proto.Message) error {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return err
	}
	size := binary.BigEndian.Uint32(header[:])
	if size > MaxFrame {
		return errors.New("message too large")
	}
	data := make([]byte, size)
	defer clear(data)
	if _, err := io.ReadFull(r, data); err != nil {
		return err
	}
	return proto.Unmarshal(data, message)
}
