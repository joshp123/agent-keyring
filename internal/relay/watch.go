// Written by AI on 2026.11.18 by model claude opus 5.5.
package relay

import (
	"bufio"
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/keyring"
)

// serveWatchAnswer takes one "POST /v2/answer" or "POST /v2/arrived" over
// HTTPS: the Watch cannot open the framed connection. Each is trusted by its
// signature alone, so this route adds no trust of its own.
func (s *Server) serveWatchAnswer(ctx context.Context, conn net.Conn) {
	reply := func(status int, body []byte) {
		response := &http.Response{StatusCode: status, ProtoMajor: 1, ProtoMinor: 1, ContentLength: int64(len(body)),
			Header: http.Header{"Content-Type": {"application/octet-stream"}}, Body: io.NopCloser(strings.NewReader(string(body)))}
		if status != http.StatusOK {
			response.Header.Set("Content-Type", "text/plain; charset=utf-8")
		}
		response.Write(conn)
	}
	request, err := http.ReadRequest(bufio.NewReader(conn))
	if err != nil {
		return
	}
	if request.Method == http.MethodPost && request.URL.Path == "/v2/arrived" {
		raw, err := io.ReadAll(io.LimitReader(request.Body, 1<<16))
		arrival := &pb.Signed{}
		if err != nil || unmarshal(raw, arrival) != nil {
			reply(http.StatusBadRequest, []byte("The body must be a signed Arrival."))
			return
		}
		if err := s.arrived(arrival); err != nil {
			reply(http.StatusForbidden, []byte(err.Error()))
			return
		}
		reply(http.StatusOK, nil)
		return
	}
	if request.Method != http.MethodPost || request.URL.Path != "/v2/answer" {
		reply(http.StatusNotFound, []byte("Only POST /v2/answer and /v2/arrived are served here."))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(request.Body, 1<<20))
	upload := &pb.AnswerUpload{}
	if err != nil || unmarshal(raw, upload) != nil || upload.Answer == nil || upload.DenyRequestId != "" {
		reply(http.StatusBadRequest, []byte("The body must be a signed AnswerUpload."))
		return
	}
	members, _ := s.Store.documents()
	signer, err := keyring.Verify(upload.Answer, members, true)
	if err != nil || signer.Kind != pb.DeviceKind_DEVICE_KIND_WATCH {
		reply(http.StatusForbidden, []byte("Only an answer signed by a Watch in the list of devices is taken here."))
		return
	}
	lease, err := s.answer(ctx, caller{device: signer}, upload)
	if err != nil {
		var known failure
		message := "The relay could not record the answer. Try again."
		status := http.StatusInternalServerError
		if ok := asFailure(err, &known); ok {
			message, status = known.message, http.StatusConflict
		}
		reply(status, []byte(message))
		return
	}
	slog.Info("watch answer", "device", signer.Label, "state", lease.State.String())
	reply(http.StatusOK, marshal(lease))
}

func asFailure(err error, target *failure) bool {
	f, ok := err.(failure)
	if ok {
		*target = f
	}
	return ok
}
