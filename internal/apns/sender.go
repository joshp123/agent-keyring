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

type Config struct{ KeyPath, KeyID, TeamID, Topic, TestGateway, TestCA string }
type Sender struct {
	config Config
	key    *ecdsa.PrivateKey
	client *http.Client
	mu     sync.Mutex
	token  string
	issued time.Time
}
type Result struct {
	Status       int
	Reason       string
	RetryAt      time.Time
	InvalidToken bool
}

func New(config Config) (*Sender, error) {
	if config.KeyID == "" || config.TeamID == "" || config.Topic == "" {
		return nil, errors.New("APNs needs a key path, key ID, team ID and topic")
	}
	data, err := os.ReadFile(config.KeyPath)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	clear(data)
	if block == nil {
		return nil, errors.New("APNs key must be PKCS#8 PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	clear(block.Bytes)
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
	return &Sender{config: config, key: key, client: &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}, nil
}
func (s *Sender) authorization() (string, error) {
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
func (s *Sender) Send(ctx context.Context, token []byte, production bool, collapse string, expires int64) (Result, error) {
	gateway := "https://api.sandbox.push.apple.com"
	environment := "sandbox"
	if production {
		gateway = "https://api.push.apple.com"
		environment = "production"
	}
	if s.config.TestGateway != "" {
		gateway = strings.TrimRight(s.config.TestGateway, "/") + "/" + environment
	}
	authorization, err := s.authorization()
	if err != nil {
		return Result{}, err
	}
	// No request metadata, site, account, password or answer goes to Apple.
	payload := []byte(`{"aps":{"alert":"An agent is asking for a login.","sound":"default"}}`)
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, gateway+"/3/device/"+hex.EncodeToString(token), bytes.NewReader(payload))
	if err != nil {
		return Result{}, err
	}
	request.Header.Set("authorization", "bearer "+authorization)
	request.Header.Set("apns-topic", s.config.Topic)
	request.Header.Set("apns-push-type", "alert")
	request.Header.Set("apns-priority", "10")
	request.Header.Set("apns-collapse-id", collapse)
	request.Header.Set("apns-expiration", strconv.FormatInt(expires, 10))
	request.Header.Set("content-type", "application/json")
	response, err := s.client.Do(request)
	if err != nil {
		return Result{}, errors.New("APNs transport failed")
	}
	defer response.Body.Close()
	result := Result{Status: response.StatusCode}
	if response.ProtoMajor != 2 {
		return result, errors.New("APNs requires HTTP/2")
	}
	if response.StatusCode == 200 {
		return result, nil
	}
	var failure struct {
		Reason string `json:"reason"`
	}
	if err = json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&failure); err == nil {
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
