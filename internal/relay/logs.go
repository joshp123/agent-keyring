// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// What the relay did, and each device's own account, kept so an agent can
// find out what happened to a request without a cable or Josh's password.
// Lines carry IDs, states and reasons, never secrets.
package relay

import (
	"context"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/joshp123/agent-keyring/internal/keyring"
)

const keptLines = 1000

// Ring keeps the last lines the relay logged, in the devices' line format.
type Ring struct {
	mu    sync.Mutex
	lines []string
}

func (r *Ring) add(line string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lines = append(r.lines, line)
	if len(r.lines) > keptLines {
		r.lines = slices.Clone(r.lines[len(r.lines)-keptLines:])
	}
}

func (r *Ring) all() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.lines)
}

// Handler writes each record to next as before, and a line to the ring:
// "<UTC time> relay <message> key=value ...".
func (r *Ring) Handler(next slog.Handler) slog.Handler { return ringHandler{ring: r, next: next} }

type ringHandler struct {
	ring  *Ring
	next  slog.Handler
	attrs []slog.Attr
}

func (h ringHandler) Enabled(ctx context.Context, level slog.Level) bool { return h.next.Enabled(ctx, level) }

func (h ringHandler) Handle(ctx context.Context, record slog.Record) error {
	var line strings.Builder
	line.WriteString(record.Time.UTC().Format("2006-01-02T15:04:05.000Z") + " relay " + logValue(record.Message))
	write := func(a slog.Attr) bool {
		line.WriteString(" " + a.Key + "=" + logValue(a.Value.String()))
		return true
	}
	for _, a := range h.attrs {
		write(a)
	}
	record.Attrs(write)
	h.ring.add(line.String())
	return h.next.Handle(ctx, record)
}

func (h ringHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return ringHandler{ring: h.ring, next: h.next.WithAttrs(attrs), attrs: append(slices.Clone(h.attrs), attrs...)}
}

func (h ringHandler) WithGroup(name string) slog.Handler {
	return ringHandler{ring: h.ring, next: h.next.WithGroup(name), attrs: h.attrs}
}

// logValue quotes a value with a space, as the devices do.
func logValue(value string) string {
	if strings.ContainsAny(value, " \"=") || value == "" {
		return fmt.Sprintf("%q", value)
	}
	return value
}

// reportLog keeps a device's latest log, signed by its reply key.
func (s *Server) reportLog(document *pb.Signed) error {
	members, _ := s.Store.documents()
	signer, err := keyring.Verify(document, members, true)
	report := &pb.DeviceLog{}
	if err != nil || unmarshal(document.Payload, report) != nil || report.Domain != keyring.LogDomain || report.DeviceKeyId != signer.KeyId {
		return fail(pb.ErrorCode_ERROR_CODE_INVALID, "A log is signed by the device it comes from.")
	}
	if len(report.Lines) > keptLines {
		report.Lines = report.Lines[len(report.Lines)-keptLines:]
	}
	s.logsMu.Lock()
	defer s.logsMu.Unlock()
	if s.deviceLogs == nil {
		s.deviceLogs = map[string][]string{}
	}
	s.deviceLogs[signer.KeyId] = report.Lines
	return nil
}

// logs merges the relay's lines and each device's latest, in time order:
// every line starts with its UTC time, so the text sorts as the time does.
func (s *Server) logs(request *pb.LogsRequest) *pb.Logs {
	var lines []string
	if s.Ring != nil {
		lines = s.Ring.all()
	}
	s.logsMu.Lock()
	for _, device := range s.deviceLogs {
		lines = append(lines, device...)
	}
	s.logsMu.Unlock()
	since := ""
	if request.SinceUnixSeconds > 0 {
		since = time.Unix(request.SinceUnixSeconds, 0).UTC().Format("2006-01-02T15:04:05.000Z")
	}
	kept := lines[:0]
	for _, line := range lines {
		if line >= since && (request.RequestId == "" || strings.Contains(line, request.RequestId)) {
			kept = append(kept, line)
		}
	}
	slices.Sort(kept)
	return &pb.Logs{Lines: slices.Compact(kept)}
}
