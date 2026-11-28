// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// APNs uses JSON and JOSE by Apple's wire contract; relay state remains protobuf.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// DefaultRelayURL is the stateless blind APNs push-signing relay hosted on
// OpenTrawl's AWS infrastructure for users who do not supply their own Apple
// Developer .p8 push key. It receives only already-encrypted payloads and
// forwards them to Apple.
const DefaultRelayURL = "https://push.opentrawl.sh"

type PushSenderConfig struct{ KeyPath, KeyID, TeamID, RelayURL, TestGateway, TestCA string }
type PushNotificationSender struct {
	config PushSenderConfig
	key    *ecdsa.PrivateKey
	client *http.Client
	mu     sync.Mutex
	token  string
	issued time.Time
}
type PushDeliveryResult struct {
	Status       int
	Reason       string
	RetryAt      time.Time
	InvalidToken bool
}

func NewDirectPushSender(config PushSenderConfig) (*PushNotificationSender, error) {
	data, err := os.ReadFile(config.KeyPath)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	clear(data)
	if block == nil {
		return nil, errors.New("APNs key must be PKCS#8 PEM")
	}
	defer clear(block.Bytes)
	return NewPushSenderWithKey(block.Bytes, config)
}

// NewPushSenderWithKey is a sender for a PKCS#8 DER key given in memory: a computer's
// own copy of the push credential (keyring.proto, PushCredential).
func NewPushSenderWithKey(pkcs8 []byte, config PushSenderConfig) (*PushNotificationSender, error) {
	if config.KeyID == "" || config.TeamID == "" {
		return nil, errors.New("APNs needs a key, key ID and team ID")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(pkcs8)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve != elliptic.P256() {
		return nil, errors.New("APNs token key must be P-256")
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ForceAttemptHTTP2 = true
	if config.TestGateway != "" {
		roots := x509.NewCertPool()
		data, err := os.ReadFile(config.TestCA)
		if err != nil {
			return nil, err
		}
		if !roots.AppendCertsFromPEM(data) {
			return nil, errors.New("Invalid test gateway CA")
		}
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}
	}
	return &PushNotificationSender{config: config, key: key, client: &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

// NewRelayPushSender sends encrypted APNs payloads through a stateless blind push-signing
// forwarder (such as https://push.opentrawl.sh) when this computer does not hold
// its own Apple Developer .p8 key.
func NewRelayPushSender(relayURL string, config PushSenderConfig) (*PushNotificationSender, error) {
	relayURL = strings.TrimSpace(relayURL)
	if relayURL == "" {
		return nil, errors.New("APNs relay URL is empty")
	}
	config.RelayURL = strings.TrimRight(relayURL, "/")
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.ForceAttemptHTTP2 = true
	if config.TestCA != "" {
		roots := x509.NewCertPool()
		data, err := os.ReadFile(config.TestCA)
		if err != nil {
			return nil, err
		}
		if !roots.AppendCertsFromPEM(data) {
			return nil, errors.New("Invalid test gateway CA")
		}
		transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}
	}
	return &PushNotificationSender{config: config, client: &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}

// SetPushAuthToken starts from a token another process made, so that a computer's
// processes give Apple one token, not one each (Apple refuses new tokens
// more often than every 20 minutes).
func (s *PushNotificationSender) SetPushAuthToken(token string, issued time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.token, s.issued = token, issued
}

func (s *PushNotificationSender) ReadCachedPushToken() (string, time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.token, s.issued
}

func (s *PushNotificationSender) pushAuthorizationHeader() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token != "" && time.Since(s.issued) < 30*time.Minute {
		return s.token, nil
	}
	now := time.Now()
	header, _ := json.Marshal(struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}{"ES256", s.config.KeyID})
	claims, _ := json.Marshal(struct {
		Issuer string `json:"iss"`
		Issued int64  `json:"iat"`
	}{s.config.TeamID, now.Unix()})
	unsigned := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(unsigned))
	r, v, err := ecdsa.Sign(rand.Reader, s.key, digest[:])
	if err != nil {
		return "", err
	}
	signature := r.FillBytes(make([]byte, 32))
	signature = append(signature, v.FillBytes(make([]byte, 32))...)
	s.token = unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
	s.issued = now
	return s.token, nil
}

// SendPushNotification delivers one push: `visible`, an alert he sees; otherwise a silent
// background push that wakes the app. The payload is the caller's: it must
// carry nothing readable about a request (keyring.proto, "The push").
func (s *PushNotificationSender) SendPushNotification(ctx context.Context, token []byte, topic string, production bool, collapse string, expires int64, payload []byte, visible bool) (PushDeliveryResult, error) {
	gateway := "https://api.sandbox.push.apple.com"
	environment := "sandbox"
	if production {
		gateway = "https://api.push.apple.com"
		environment = "production"
	}
	usingRelay := s.config.RelayURL != ""
	if usingRelay {
		gateway = s.config.RelayURL
	} else if s.config.TestGateway != "" {
		gateway = strings.TrimRight(s.config.TestGateway, "/") + "/" + environment
	}
	// Through the relay the address goes in a header, never the URL, so nothing that logs URLs sees it.
	path := "/3/device/" + hex.EncodeToString(token)
	if usingRelay {
		path = "/v1/push"
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, gateway+path, bytes.NewReader(payload))
	if err != nil {
		return PushDeliveryResult{}, err
	}
	if usingRelay {
		request.Header.Set("x-apns-env", environment)
		request.Header.Set("x-akr-token", hex.EncodeToString(token))
	} else {
		authorization, err := s.pushAuthorizationHeader()
		if err != nil {
			return PushDeliveryResult{}, err
		}
		request.Header.Set("authorization", "bearer "+authorization)
	}
	request.Header.Set("apns-topic", topic)
	if visible {
		request.Header.Set("apns-push-type", "alert")
		request.Header.Set("apns-priority", "10")
	} else {
		request.Header.Set("apns-push-type", "background")
		request.Header.Set("apns-priority", "5") // Apple requires 5 for background pushes.
	}
	request.Header.Set("apns-collapse-id", collapse)
	request.Header.Set("apns-expiration", strconv.FormatInt(expires, 10))
	request.Header.Set("content-type", "application/json")
	response, err := s.client.Do(request)
	if err != nil {
		return PushDeliveryResult{}, fmt.Errorf("APNs transport failed: %w", err)
	}
	defer func() { _ = response.Body.Close() }()
	result := PushDeliveryResult{Status: response.StatusCode}
	if !usingRelay && response.ProtoMajor != 2 {
		return result, errors.New("APNs requires HTTP/2")
	}
	if response.StatusCode == 200 {
		return result, nil
	}
	return apnsRejection(response, result)
}

func apnsRejection(response *http.Response, result PushDeliveryResult) (PushDeliveryResult, error) {
	var failure struct {
		Reason string `json:"reason"`
	}
	if err := json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&failure); err == nil {
		result.Reason = failure.Reason
	}
	result.InvalidToken = response.StatusCode == 410 || failure.Reason == "BadDeviceToken" || failure.Reason == "DeviceTokenNotForTopic"
	if response.StatusCode >= 500 {
		result.RetryAt = time.Now().Add(15 * time.Minute)
	} else if response.StatusCode == 429 {
		result.RetryAt = time.Now().Add(time.Minute)
		if seconds, err := strconv.Atoi(response.Header.Get("Retry-After")); err == nil && seconds > 0 {
			result.RetryAt = time.Now().Add(time.Duration(seconds) * time.Second)
		}
	}
	return result, fmt.Errorf("APNs refused notification: status %d", response.StatusCode)
}
