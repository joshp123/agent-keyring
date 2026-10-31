// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Package relaycrypto defines the byte contracts shared by relay and receiver.
package relaycrypto

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"strings"
	"time"
)

func transcript(parts ...[]byte) []byte {
	var result []byte
	for _, part := range parts {
		result = binary.BigEndian.AppendUint32(result, uint32(len(part)))
		result = append(result, part...)
	}
	return result
}
func EnrolTranscript(relaySPKI, clientSPKI, receiverX963, exactKeySet []byte) []byte {
	return transcript([]byte("agentkeyring.enrol.v1\x00"), relaySPKI, clientSPKI, receiverX963, exactKeySet)
}
func PairTranscript(relaySPKI, approverSPKI, signingX963, exactKeySet []byte) []byte {
	return transcript([]byte("agentkeyring.pair.v1\x00"), relaySPKI, approverSPKI, signingX963, exactKeySet)
}
func Hash(data []byte) []byte { sum := sha256.Sum256(data); return sum[:] }
func Digest(domain string, record []byte) []byte {
	return Hash(append(append([]byte(domain), 0), record...))
}
func Fingerprint(transcript []byte) string {
	encoded := strings.ToUpper(hex.EncodeToString(Hash(transcript)[:16]))
	var groups []string
	for i := 0; i < len(encoded); i += 4 {
		groups = append(groups, encoded[i:i+4])
	}
	return strings.Join(groups, " ")
}
func PublicKey(raw []byte) (*ecdsa.PublicKey, error) {
	x, y := elliptic.Unmarshal(elliptic.P256(), raw)
	if x == nil {
		return nil, errors.New("invalid P-256 public key")
	}
	return &ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, nil
}
func Verify(publicKey, statement, signature []byte) error {
	key, err := PublicKey(publicKey)
	if err != nil {
		return err
	}
	if !ecdsa.VerifyASN1(key, Hash(statement), signature) {
		return errors.New("invalid signature")
	}
	return nil
}
func CertificateSPKI(certificate tls.Certificate) ([]byte, error) {
	if len(certificate.Certificate) == 0 {
		return nil, errors.New("missing TLS certificate")
	}
	parsed, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil {
		return nil, err
	}
	return parsed.RawSubjectPublicKeyInfo, nil
}

// ClientConfig authenticates the peer by its exact SPKI, independent of DNS or
// certificate issuer. A nil pin is refused; setup observation is a separate API.
func ClientConfig(certificate tls.Certificate, pinnedSPKI []byte) (*tls.Config, error) {
	if len(pinnedSPKI) == 0 {
		return nil, errors.New("missing relay TLS pin")
	}
	return ObservingClientConfig(certificate, func(observed []byte) error {
		if !bytes.Equal(pinnedSPKI, observed) {
			return errors.New("relay TLS key changed")
		}
		return nil
	}), nil
}

// ObservingClientConfig is for code-comparison setup only. Its caller must bind
// the observed SPKI into the locally computed transcript before trusting keys.
func ObservingClientConfig(certificate tls.Certificate, observe func([]byte) error) *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}, InsecureSkipVerify: true, VerifyConnection: func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) != 1 {
			return errors.New("expected one pinned TLS certificate")
		}
		cert := state.PeerCertificates[0]
		if time.Now().Before(cert.NotBefore) || time.Now().After(cert.NotAfter) {
			return errors.New("TLS certificate expired or not yet valid")
		}
		if observe == nil {
			return errors.New("missing TLS key observer")
		}
		return observe(cert.RawSubjectPublicKeyInfo)
	}}
}
func NewIdentity(label string) (certificatePEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: label}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().AddDate(10, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private}), nil
}
