// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package authority

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"google.golang.org/protobuf/proto"
)

const MaxFrame = 1 << 20

type Client struct {
	Socket     string
	Start      func(context.Context) error
	Exchange   func(context.Context, *pb.WireRequest, func(*pb.WireResponse) bool) error
	OpenValues func(context.Context, *pb.Lease, *pb.Delivery) (*pb.CredentialValues, []string, error)
	Remote     bool
	State      clientstate.Store
}

func WriteFrame(w io.Writer, message proto.Message) error {
	data, err := proto.Marshal(message)
	if err != nil {
		return err
	}
	if len(data) == 0 || len(data) > MaxFrame {
		return errors.New("invalid message size")
	}
	framed := make([]byte, 4+len(data))
	binary.BigEndian.PutUint32(framed, uint32(len(data)))
	copy(framed[4:], data)
	for len(framed) > 0 {
		n, err := w.Write(framed)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		framed = framed[n:]
	}
	return nil
}
func ReadFrame(r io.Reader, message proto.Message) error {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return err
	}
	size := binary.BigEndian.Uint32(header[:])
	if size == 0 || size > MaxFrame {
		return errors.New("invalid message size")
	}
	data := make([]byte, size)
	defer clear(data)
	if _, err := io.ReadFull(r, data); err != nil {
		return err
	}
	return proto.Unmarshal(data, message)
}
func (c Client) Call(ctx context.Context, request *pb.WireRequest) (*pb.WireResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	var result *pb.WireResponse
	err := c.Stream(ctx, request, func(response *pb.WireResponse) bool { result = response; return false })
	return result, err
}
func (c Client) Stream(ctx context.Context, request *pb.WireRequest, receive func(*pb.WireResponse) bool) error {
	if c.Exchange != nil {
		return c.Exchange(ctx, request, receive)
	}
	conn, err := (&net.Dialer{Timeout: 3 * time.Second}).DialContext(ctx, "unix", c.Socket)
	if err != nil && c.Start != nil {
		if startError := c.Start(ctx); startError != nil {
			return startError
		}
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-deadline.C:
				return errors.New("Agent Keyring started, but its local connection is not ready. Try the same command again.")
			case <-time.After(100 * time.Millisecond):
				conn, err = (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "unix", c.Socket)
			}
		}
	}
	if err != nil {
		return errors.New("Cannot connect to Agent Keyring. Open the app, then run this command again.")
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if err = WriteFrame(conn, request); err != nil {
		return errors.New("Could not send the request. Rejoin an existing lease with 'status LEASE --wait'.")
	}
	for {
		conn.SetReadDeadline(time.Now().Add(11 * time.Minute))
		response := new(pb.WireResponse)
		if err = ReadFrame(conn, response); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return errors.New("The connection ended before a result arrived. Rejoin the same lease; do not request approval again.")
		}
		if failure := response.GetError(); failure != nil {
			return fmt.Errorf("%s", failure.Message)
		}
		if response.Response == nil {
			return errors.New("Agent Keyring returned an empty response. Update the app and CLI together.")
		}
		if !receive(response) || response.EndOfStream {
			return nil
		}
	}
}
func (c Client) Lease(ctx context.Context, id string) (*pb.Lease, error) {
	r, e := c.Call(ctx, &pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: id}}})
	if e != nil {
		return nil, e
	}
	if r.GetLease() == nil {
		return nil, errors.New("Agent Keyring did not return a lease.")
	}
	return r.GetLease(), nil
}
func (c Client) Deliver(ctx context.Context, request *pb.DeliverRequest) (*pb.Delivery, error) {
	response, err := c.Call(ctx, &pb.WireRequest{Request: &pb.WireRequest_Deliver{Deliver: request}})
	if err != nil {
		return nil, err
	}
	if response.GetDelivery() == nil {
		return nil, errors.New("Agent Keyring did not return a delivery.")
	}
	return response.GetDelivery(), nil
}
