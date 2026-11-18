// Written by AI on 2026.11.18 by model claude opus 5.5.
// Package tlsid makes the self-signed TLS identities that the relay, machines
// and devices pin each other by, and the client side of that pinning.
package tlsid

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"time"
)

// New makes a P-256 key and a ten-year self-signed certificate for it, as PEM.
func New(label string) (certificatePEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}
	template := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: label},
		NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().AddDate(10, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}}
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

// SPKI is the certificate's SubjectPublicKeyInfo DER: what peers pin.
func SPKI(certificate tls.Certificate) ([]byte, error) {
	if len(certificate.Certificate) == 0 {
		return nil, errors.New("missing TLS certificate")
	}
	parsed, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil {
		return nil, err
	}
	return parsed.RawSubjectPublicKeyInfo, nil
}

// Client trusts exactly the pinned relay key. With no pin (the first
// connection, while joining) it records the key it saw in observed.
func Client(certificate tls.Certificate, pinned []byte, observed *[]byte) *tls.Config {
	return &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}, InsecureSkipVerify: true,
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) != 1 {
				return errors.New("expected one relay certificate")
			}
			seen := state.PeerCertificates[0].RawSubjectPublicKeyInfo
			if len(pinned) == 0 {
				if observed == nil {
					return errors.New("no relay key is pinned")
				}
				*observed = bytes.Clone(seen)
				return nil
			}
			if !bytes.Equal(seen, pinned) {
				return errors.New("the relay's key has changed; refusing to connect")
			}
			return nil
		}}
}
