// Written by AI on 2026.11.18 by model claude opus 5.5; the pinning cut with the doors on 2026.11.24.
// Package tlsid makes a machine's identity: a P-256 key in a self-signed
// certificate. Members lists its SubjectPublicKeyInfo as the machine's
// tls_public_key, and the machine signs its requests with the key.
package tlsid

import (
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

// GenerateDeviceTLSCertificate makes a P-256 key and a ten-year self-signed certificate for it, as PEM.
func GenerateDeviceTLSCertificate(label string) (certificatePEM, keyPEM []byte, err error) {
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

// ExtractCertificateSPKI is the certificate's SubjectPublicKeyInfo DER: what peers pin.
func ExtractCertificateSPKI(certificate tls.Certificate) ([]byte, error) {
	if len(certificate.Certificate) == 0 {
		return nil, errors.New("missing TLS certificate")
	}
	parsed, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil {
		return nil, err
	}
	return parsed.RawSubjectPublicKeyInfo, nil
}
