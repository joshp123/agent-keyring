// Written by AI on 2026.11.23 by model claude opus 5.5.
// Handler construction updated on 2026.11.28 by model gpt-6.2-sol.

// Package boxserver serves the self-hosted relay's in-memory box storage.
package boxserver

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	maxBytes = 256 << 10
	// At most this many boxes at once, about 1 GiB if every one were full.
	maxBoxes = 4096
)

var (
	boxIDPattern   = regexp.MustCompile(`^[0-9a-f]{32,64}$`)
	boxPathPattern = regexp.MustCompile(`^/v1/box/([0-9a-f]{32,64})$`)
	tokenPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{32,128}$`)
	etagPattern    = regexp.MustCompile(`^[0-9a-f]{32}$`)
)

type storedRelayBox struct {
	payload   []byte
	etag      string
	expires   time.Time
	readHash  string // SHA-256 of the read token, hex; "" for none.
	writeHash string
	stopped   *bool // Only on a grant.
}

type relayBoxServer struct {
	mu    sync.Mutex
	boxes map[string]*storedRelayBox
	ttls  map[string]time.Duration
}

// NewRelayBoxHandler serves an empty relay and purges expired boxes until ctx
// is cancelled. ttlScale is 1 in production and shortens box lifetimes in tests.
func NewRelayBoxHandler(ctx context.Context, ttlScale float64) http.Handler {
	scaled := func(lifetime time.Duration) time.Duration {
		return time.Duration(float64(lifetime) * ttlScale)
	}
	s := &relayBoxServer{
		boxes: make(map[string]*storedRelayBox),
		ttls: map[string]time.Duration{
			"enrol":  scaled(10 * time.Minute),
			"grant":  scaled(45 * time.Minute),
			"update": scaled(7 * 24 * time.Hour),
		},
	}
	go s.runRelayBoxExpirySweep(ctx)
	return s
}

func (s *relayBoxServer) runRelayBoxExpirySweep(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.mu.Lock()
			s.sweepExpiredRelayBoxes(time.Now())
			s.mu.Unlock()
		}
	}
}

func writeRelayResponse(w http.ResponseWriter, status int, body map[string]any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	// The response has started. A disconnected client cannot receive an error.
	_ = json.NewEncoder(w).Encode(body)
}

func writeRelayRefusal(w http.ResponseWriter, status int, reason string) {
	writeRelayResponse(w, status, map[string]any{"reason": reason})
}

func (s *relayBoxServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case r.Method == http.MethodGet && path == "/health":
		writeRelayResponse(w, http.StatusOK, map[string]any{"ok": true})
		return
	case path != "/v1/box" && !strings.HasPrefix(path, "/v1/box/"):
		writeRelayResponse(w, http.StatusNotFound, map[string]any{"error": "Not found"})
		return
	}
	id := ""
	if path == "/v1/box" {
		if header := strings.TrimSpace(r.Header.Get("x-akr-box")); boxIDPattern.MatchString(header) {
			id = header
		}
	} else if match := boxPathPattern.FindStringSubmatch(path); match != nil {
		id = match[1]
	}
	switch {
	case id == "":
		writeRelayRefusal(w, http.StatusBadRequest, "BadBoxId")
	case r.Method == http.MethodPut:
		s.serveRelayBoxPut(w, r, id)
	case r.Method == http.MethodGet:
		s.serveRelayBoxGet(w, r, id)
	case r.Method == http.MethodDelete:
		s.serveRelayBoxDelete(w, r, id)
	default:
		writeRelayRefusal(w, http.StatusMethodNotAllowed, "MethodNotAllowed")
	}
}

// hashRelayAuthToken is an optional token's SHA-256: ok false if one is given but malformed.
func hashRelayAuthToken(raw string) (hash string, ok bool) {
	if raw == "" {
		return "", true
	}
	if !tokenPattern.MatchString(raw) {
		return "", false
	}
	digest := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(digest[:]), true
}

func newEtag() string {
	raw := make([]byte, 16)
	rand.Read(raw)
	return hex.EncodeToString(raw)
}

func (s *relayBoxServer) serveRelayBoxPut(w http.ResponseWriter, r *http.Request, id string) {
	if kind, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type")); kind != "application/octet-stream" {
		writeRelayRefusal(w, http.StatusUnsupportedMediaType, "UnsupportedMediaType")
		return
	}
	ttlName := strings.ToLower(strings.TrimSpace(r.Header.Get("x-akr-ttl")))
	if ttlName == "" {
		ttlName = "enrol"
	}
	ttl, ok := s.ttls[ttlName]
	if !ok {
		writeRelayRefusal(w, http.StatusBadRequest, "BadTtl")
		return
	}
	mode := strings.ToLower(strings.TrimSpace(r.Header.Get("x-akr-mode")))
	if mode == "" {
		mode = "create"
	}
	if mode != "create" && mode != "replace" && mode != "stop" {
		writeRelayRefusal(w, http.StatusBadRequest, "BadMode")
		return
	}
	readHash, readOK := hashRelayAuthToken(r.Header.Get("x-akr-read-auth"))
	writeHash, writeOK := hashRelayAuthToken(r.Header.Get("x-akr-write-auth"))
	if !readOK || !writeOK {
		writeRelayRefusal(w, http.StatusBadRequest, "BadAuth")
		return
	}
	if (mode == "replace" || mode == "stop") && writeHash == "" {
		writeRelayRefusal(w, http.StatusBadRequest, "MissingWriteAuth")
		return
	}
	if mode == "replace" && ttlName == "grant" {
		writeRelayRefusal(w, http.StatusBadRequest, "BadMode")
		return
	}
	payload, err := io.ReadAll(io.LimitReader(r.Body, maxBytes+1))
	switch {
	case err != nil:
		writeRelayRefusal(w, http.StatusBadRequest, "BadPayload")
		return
	case len(payload) == 0:
		writeRelayRefusal(w, http.StatusBadRequest, "PayloadEmpty")
		return
	case len(payload) > maxBytes:
		writeRelayRefusal(w, http.StatusRequestEntityTooLarge, "PayloadTooLarge")
		return
	}
	s.saveBox(w, id, ttlName, mode, &storedRelayBox{payload: payload, readHash: readHash, writeHash: writeHash}, ttl)
}

func (s *relayBoxServer) saveBox(w http.ResponseWriter, id, ttlName, mode string, next *storedRelayBox, ttl time.Duration) {
	now := time.Now()
	s.mu.Lock()
	defer s.mu.Unlock()
	existing, live := s.boxes[id]
	live = live && existing.expires.After(now)
	etag := newEtag()
	w.Header().Set("Cache-Control", "no-store")
	if mode == "stop" {
		// Stopped for good: kept a grant's lifetime from now. Only a grant stops.
		if !live || existing.stopped == nil || existing.writeHash != next.writeHash {
			writeRelayRefusal(w, http.StatusForbidden, "Forbidden")
			return
		}
		stopped := true
		existing.payload, existing.stopped, existing.etag, existing.expires = next.payload, &stopped, etag, now.Add(s.ttls["grant"])
		w.Header().Set("x-akr-etag", etag)
		w.Header().Set("x-akr-stopped", "true")
		w.WriteHeader(http.StatusOK)
		return
	}
	// A replace never touches a live grant: that would clear its Stop.
	if live && (mode == "create" || existing.writeHash != next.writeHash || existing.stopped != nil) {
		if mode == "replace" {
			writeRelayRefusal(w, http.StatusForbidden, "Forbidden")
		} else {
			writeRelayRefusal(w, http.StatusConflict, "BoxExists")
		}
		return
	}
	if !live && len(s.boxes) >= maxBoxes {
		s.sweepExpiredRelayBoxes(now)
	}
	if !live && len(s.boxes) >= maxBoxes {
		writeRelayRefusal(w, http.StatusTooManyRequests, "TooManyRequests")
		return
	}
	next.etag, next.expires = etag, now.Add(ttl)
	w.Header().Set("x-akr-etag", etag)
	if ttlName == "grant" && mode == "create" {
		next.stopped = new(bool)
		w.Header().Set("x-akr-stopped", "false")
	}
	s.boxes[id] = next
	w.WriteHeader(http.StatusCreated)
}

func (s *relayBoxServer) serveRelayBoxGet(w http.ResponseWriter, r *http.Request, id string) {
	readHash, ok := hashRelayAuthToken(r.Header.Get("x-akr-read-auth"))
	if !ok {
		writeRelayRefusal(w, http.StatusBadRequest, "BadAuth")
		return
	}
	s.mu.Lock()
	found, exists := s.boxes[id]
	var b storedRelayBox
	if exists {
		b = *found
	}
	s.mu.Unlock()
	if !exists || !b.expires.After(time.Now()) {
		writeRelayRefusal(w, http.StatusNotFound, "NotFound")
		return
	}
	if b.readHash != "" && subtle.ConstantTimeCompare([]byte(readHash), []byte(b.readHash)) != 1 {
		writeRelayRefusal(w, http.StatusForbidden, "Forbidden")
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("x-akr-etag", b.etag)
	if b.stopped != nil {
		w.Header().Set("x-akr-stopped", fmt.Sprint(*b.stopped))
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(b.payload)
}

// serveRelayBoxDelete takes a box away, only with its read token, never a grant, and with
// x-akr-if-etag only while it is that etag. As push.opentrawl.sh answers: a
// condition that fails is 409 with an etag given (also for a box already
// gone) and 403 without; a box gone or expired with no etag given is 404.
func (s *relayBoxServer) serveRelayBoxDelete(w http.ResponseWriter, r *http.Request, id string) {
	readHash, ok := hashRelayAuthToken(r.Header.Get("x-akr-read-auth"))
	if !ok {
		writeRelayRefusal(w, http.StatusBadRequest, "BadAuth")
		return
	}
	ifEtag := r.Header.Get("x-akr-if-etag")
	if ifEtag != "" && !etagPattern.MatchString(ifEtag) {
		writeRelayRefusal(w, http.StatusBadRequest, "BadEtag")
		return
	}
	s.mu.Lock()
	found, exists := s.boxes[id]
	allowed := (!exists || found.readHash == "" || found.readHash == readHash) &&
		(!exists || found.stopped == nil) && (ifEtag == "" || (exists && found.etag == ifEtag))
	if allowed {
		delete(s.boxes, id)
	}
	s.mu.Unlock()
	switch {
	case !allowed && ifEtag != "":
		writeRelayRefusal(w, http.StatusConflict, "EtagMismatch")
	case !allowed:
		writeRelayRefusal(w, http.StatusForbidden, "Forbidden")
	case !exists || !found.expires.After(time.Now()):
		writeRelayRefusal(w, http.StatusNotFound, "NotFound")
	default:
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("x-akr-etag", found.etag)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(found.payload)
	}
}

// sweepExpiredRelayBoxes forgets boxes past their time. Hold s.mu.
func (s *relayBoxServer) sweepExpiredRelayBoxes(now time.Time) {
	for id, b := range s.boxes {
		if !b.expires.After(now) {
			delete(s.boxes, id)
		}
	}
}
