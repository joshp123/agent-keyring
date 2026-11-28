// Written by AI on 2026.11.23 by model claude opus 5.5; GET, the conditional
// DELETE, tokens and modes on 2026.11.24.
package box

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"time"
)

// putFor is how long a put keeps retrying a relay that cannot be reached, is
// busy (429) or fails (5xx).
const putFor = 30 * time.Second

// RelayBoxPollInterval is how long a side waiting on a box waits before it looks again,
// having waited `waited` so far: half a second for the first 15 seconds, a
// second to a minute, then 3 seconds, each up to 10% sooner or later.
func RelayBoxPollInterval(waited time.Duration) time.Duration {
	every := 3 * time.Second
	switch {
	case waited < 15*time.Second:
		every = 500 * time.Millisecond
	case waited < time.Minute:
		every = time.Second
	}
	jitter, _ := rand.Int(rand.Reader, big.NewInt(int64(every/5)+1))
	return every - every/10 + time.Duration(jitter.Int64())
}

// RelayBoxClient puts, reads and deletes boxes at one relay. It follows no
// redirects. Box ids travel in headers, so its errors and the URL never name one.
type RelayBoxClient struct {
	URL  string
	HTTP *http.Client
}

// NewRelayBoxClient is a client for a relay URL already checked with ValidateRelayBoxURL.
func NewRelayBoxClient(relay string) *RelayBoxClient {
	return &RelayBoxClient{URL: relay, HTTP: &http.Client{Timeout: 30 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

// RelayBoxPutOptions is how a PUT keeps its box: x-akr-ttl, x-akr-mode and the tokens.
// The zero value is a box that lasts 600 seconds, put once, with no tokens.
type RelayBoxPutOptions struct {
	TTL, Mode           string
	ReadAuth, WriteAuth string
}

var (
	// ErrExists is a create of a box that already holds a message: someone else answered first.
	ErrExists = errors.New("that box already holds a message")
	// ErrForbidden is a token the relay refused, or a stop of a grant that is not there.
	ErrForbidden = errors.New("the relay refused this box's token")
)

// retryableRelayError is a relay that could not be reached, is busy or failed: worth trying again.
type retryableRelayError struct{ err error }

func (r retryableRelayError) Error() string { return r.err.Error() }

// relayReply contains the reply metadata after sendRelayBoxRequest reads and closes the body.
type relayReply struct {
	StatusCode int
	Header     http.Header
}

func (c *RelayBoxClient) sendRelayBoxRequest(ctx context.Context, method, id string, headers map[string]string, body []byte) (relayReply, []byte, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, c.URL+"/v1/box", reader)
	if err != nil {
		return relayReply{}, nil, err
	}
	request.Header.Set("x-akr-box", id)
	if body != nil {
		request.Header.Set("Content-Type", "application/octet-stream")
	}
	for name, value := range headers {
		if value != "" {
			request.Header.Set(name, value)
		}
	}
	response, err := c.HTTP.Do(request)
	if err != nil {
		var urlError *url.Error
		if errors.As(err, &urlError) {
			err = urlError.Err
		}
		return relayReply{}, nil, retryableRelayError{fmt.Errorf("Cannot reach the relay at %s: %w", c.URL, err)}
	}
	defer func() { _ = response.Body.Close() }()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 256<<10+1))
	if err != nil {
		return relayReply{}, nil, retryableRelayError{fmt.Errorf("The relay's reply from %s was cut off: %w", c.URL, err)}
	}
	if response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500 {
		return relayReply{}, nil, retryableRelayError{fmt.Errorf("The relay at %s is busy or failing (status %d).", c.URL, response.StatusCode)}
	}
	return relayReply{response.StatusCode, response.Header}, raw, nil
}

// putSealedBoxChunk retries while the relay cannot be reached or is
// busy. A create sent before without hearing back that is then found there
// (409) is taken as this put's own.
func (c *RelayBoxClient) putSealedBoxChunk(ctx context.Context, id string, sealed []byte, options RelayBoxPutOptions, giveUp time.Time) (relayReply, error) {
	headers := map[string]string{"x-akr-ttl": options.TTL, "x-akr-mode": options.Mode,
		"x-akr-read-auth": options.ReadAuth, "x-akr-write-auth": options.WriteAuth}
	sent, wait := false, 500*time.Millisecond
	for {
		response, _, err := c.sendRelayBoxRequest(ctx, http.MethodPut, id, headers, sealed)
		var again retryableRelayError
		if errors.As(err, &again) {
			sent = true
			if time.Now().Add(wait).After(giveUp) {
				return relayReply{}, again.err
			}
			select {
			case <-ctx.Done():
				return relayReply{}, ctx.Err()
			case <-time.After(wait):
			}
			wait = min(2*wait, 2*time.Second)
			continue
		}
		if err != nil {
			return relayReply{}, err
		}
		switch status := response.StatusCode; {
		case status == http.StatusCreated || status == http.StatusOK:
			return response, nil
		case status == http.StatusConflict && sent:
			return response, nil
		case status == http.StatusConflict:
			return relayReply{}, ErrExists
		case status == http.StatusForbidden:
			return relayReply{}, ErrForbidden
		default:
			return relayReply{}, fmt.Errorf("The relay at %s refused the box (status %d).", c.URL, status)
		}
	}
}

// PutRelayBox seals message into box id and the parts after it, the parts first,
// so whoever reads box id finds the rest. Parts are created with the same
// ttl and no tokens; box id as options says.
func (c *RelayBoxClient) PutRelayBox(ctx context.Context, id string, key, message []byte, options RelayBoxPutOptions) error {
	nonce := make([]byte, 16)
	rand.Read(nonce)
	parts := SplitIntoBoxChunks(id, nonce, message)
	if len(parts) > MaxParts {
		return fmt.Errorf("the message is %d bytes, too large for the relay", len(message))
	}
	giveUp := time.Now().Add(putFor)
	for i := len(parts) - 1; i >= 0; i-- {
		sealed, err := SealBoxChunk(key, parts[i].ID, nil, parts[i].Plaintext)
		if err != nil {
			return err
		}
		partOptions := RelayBoxPutOptions{TTL: options.TTL}
		if i == 0 {
			partOptions = options
		}
		if _, err := c.putSealedBoxChunk(ctx, parts[i].ID, sealed, partOptions, giveUp); err != nil {
			return err
		}
	}
	return nil
}

// FetchedBoxMessage is a message read from a box, still at the relay until AcknowledgeRelayBox.
type FetchedBoxMessage struct {
	Message []byte
	// The grant's mark (x-akr-stopped), if the relay sent one: nil for any other box.
	Stopped *bool
	parts   [][2]string // Each part's box and etag, part 0 first.
}

func (c *RelayBoxClient) fetchSealedBoxChunk(ctx context.Context, id, readAuth string) ([]byte, string, *bool, error) {
	response, raw, err := c.sendRelayBoxRequest(ctx, http.MethodGet, id, map[string]string{"x-akr-read-auth": readAuth}, nil)
	switch {
	case err != nil:
		return nil, "", nil, err
	case response.StatusCode == http.StatusNotFound:
		return nil, "", nil, nil
	case response.StatusCode == http.StatusForbidden:
		return nil, "", nil, ErrForbidden
	case response.StatusCode != http.StatusOK:
		return nil, "", nil, fmt.Errorf("The relay at %s answered %d.", c.URL, response.StatusCode)
	case len(raw) > 256<<10:
		return nil, "", nil, errors.New("the box is larger than the relay allows")
	}
	var stopped *bool
	switch response.Header.Get("x-akr-stopped") {
	case "true":
		stopped = new(bool)
		*stopped = true
	case "false":
		stopped = new(bool)
	}
	return raw, response.Header.Get("x-akr-etag"), stopped, nil
}

// FetchRelayBox reads the message in box id, if one is there (nil if not), and leaves
// it at the relay. A message whose later parts are missing is an error.
func (c *RelayBoxClient) FetchRelayBox(ctx context.Context, id string, key []byte, readAuth string) (*FetchedBoxMessage, error) {
	sealed, etag, stopped, err := c.fetchSealedBoxChunk(ctx, id, readAuth)
	if err != nil || sealed == nil {
		return nil, err
	}
	first, err := OpenBoxChunk(key, id, sealed)
	if err != nil {
		return nil, err
	}
	n := uint32(0)
	if len(first) >= 20 {
		n = binary.BigEndian.Uint32(first)
	}
	if n == 0 || n > MaxParts {
		return nil, ErrUnreadable
	}
	nonce := first[4:20]
	picked := &FetchedBoxMessage{Message: append([]byte(nil), first[20:]...), Stopped: stopped, parts: [][2]string{{id, etag}}}
	for i := uint32(1); i < n; i++ {
		partID := DeriveChunkBoxID(nonce, i)
		sealed, etag, _, err := c.fetchSealedBoxChunk(ctx, partID, "")
		if err != nil {
			return nil, err
		}
		if sealed == nil {
			return nil, fmt.Errorf("part %d of %d of the message was not at the relay", i+1, n)
		}
		part, err := OpenBoxChunk(key, partID, sealed)
		if err != nil {
			return nil, err
		}
		if len(part) < 4 || binary.BigEndian.Uint32(part) != n {
			return nil, ErrUnreadable
		}
		picked.Message = append(picked.Message, part[4:]...)
		picked.parts = append(picked.parts, [2]string{partID, etag})
	}
	return picked, nil
}

// AcknowledgeRelayBox deletes a message read with FetchRelayBox, once what it said is saved: each
// part only while it is the one read (x-akr-if-etag). A part already gone
// or replaced since (404, 409) is no error.
func (c *RelayBoxClient) AcknowledgeRelayBox(ctx context.Context, picked *FetchedBoxMessage, readAuth string) error {
	for i, part := range picked.parts {
		headers := map[string]string{"x-akr-if-etag": part[1]}
		if i == 0 {
			headers["x-akr-read-auth"] = readAuth
		}
		response, _, err := c.sendRelayBoxRequest(ctx, http.MethodDelete, part[0], headers, nil)
		if err != nil {
			return err
		}
		switch response.StatusCode {
		case http.StatusOK, http.StatusNotFound, http.StatusConflict:
		default:
			return fmt.Errorf("The relay at %s did not delete the box (status %d).", c.URL, response.StatusCode)
		}
	}
	return nil
}

// WaitForRelayBox reads box id at the pace RelayBoxPollInterval gives, from started, until a message
// comes, ctx ends or until passes (context.DeadlineExceeded). A relay that
// cannot be reached for a moment is tried again. The message stays at the
// relay until AcknowledgeRelayBox.
func (c *RelayBoxClient) WaitForRelayBox(ctx context.Context, id string, key []byte, readAuth string, started, until time.Time) (*FetchedBoxMessage, error) {
	for {
		picked, err := c.FetchRelayBox(ctx, id, key, readAuth)
		var again retryableRelayError
		if picked != nil || (err != nil && !errors.As(err, &again)) {
			return picked, err
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if time.Now().After(until) {
			return nil, context.DeadlineExceeded
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(RelayBoxPollInterval(time.Since(started))):
		}
	}
}

// PublishLeaseGrantBox creates the grant of the request answered in answerBox: live, for
// 2700 seconds. A grant already there (409) is no error.
func (c *RelayBoxClient) PublishLeaseGrantBox(ctx context.Context, answerBox string, answerKey []byte, requestID string) error {
	grant := DeriveLeaseGrantBox(answerBox, answerKey)
	err := c.PutRelayBox(ctx, grant.ID, answerKey, []byte(requestID), RelayBoxPutOptions{TTL: TTLGrant, Mode: ModeCreate, ReadAuth: grant.ReadAuth, WriteAuth: grant.WriteAuth})
	if errors.Is(err, ErrExists) {
		return nil
	}
	return err
}

// StopLeaseGrantBox marks the grant of the request answered in answerBox stopped, for
// good, with the device's signed EndRequest: it creates the grant first, in
// case the asking computer has not yet. True once the relay says it is stopped.
func (c *RelayBoxClient) StopLeaseGrantBox(ctx context.Context, answerBox string, answerKey []byte, requestID string, signedEnd []byte) (bool, error) {
	if err := c.PublishLeaseGrantBox(ctx, answerBox, answerKey, requestID); err != nil {
		return false, err
	}
	grant := DeriveLeaseGrantBox(answerBox, answerKey)
	sealed, err := SealBoxChunk(answerKey, grant.ID, nil, append(binary.BigEndian.AppendUint32(nil, 1), append(make([]byte, 16), signedEnd...)...))
	if err != nil {
		return false, err
	}
	response, err := c.putSealedBoxChunk(ctx, grant.ID, sealed, RelayBoxPutOptions{TTL: TTLGrant, Mode: ModeStop, WriteAuth: grant.WriteAuth}, time.Now().Add(putFor))
	if err != nil {
		return false, err
	}
	return response.Header.Get("x-akr-stopped") == "true", nil
}
