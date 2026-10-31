// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relay

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"database/sql"
	"encoding/hex"
	"errors"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
)

func loadAutomaticKey(tx *sql.Tx, id string) (*ecdsa.PrivateKey, error) {
	var raw []byte
	err := tx.QueryRow("SELECT private FROM relay_identity WHERE id=?", id).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, err
		}
		raw, err = x509.MarshalPKCS8PrivateKey(key)
		if err != nil {
			return nil, err
		}
		defer clear(raw)
		_, err = tx.Exec("INSERT INTO relay_identity VALUES(?,?)", id, raw)
		return key, err
	}
	if err != nil {
		return nil, err
	}
	defer clear(raw)
	key, err := x509.ParsePKCS8PrivateKey(raw)
	if err != nil {
		return nil, err
	}
	value, ok := key.(*ecdsa.PrivateKey)
	if !ok || value.Curve != elliptic.P256() {
		return nil, errors.New("Invalid stored relay key")
	}
	return value, nil
}

func (s *Server) automaticKeys() *pb.AutomaticKeys {
	public := func(key *ecdsa.PrivateKey) []byte { return elliptic.Marshal(elliptic.P256(), key.X, key.Y) }
	signing, encryption := public(s.Store.automaticSigning), public(s.Store.automaticEncryption)
	return &pb.AutomaticKeys{SigningPublicKey: signing, SigningKeyId: hex.EncodeToString(relaycrypto.Hash(signing)), EncryptionPublicKey: encryption, EncryptionKeyId: hex.EncodeToString(relaycrypto.Hash(encryption))}
}

func (s *Server) delegatesAutomatic(config *pb.Configuration) bool {
	keys := s.automaticKeys()
	return config.AutomaticKeyId == keys.SigningKeyId && bytes.Equal(config.AutomaticSigningPublicKey, keys.SigningPublicKey) && bytes.Equal(config.RelayEncryptionPublicKey, keys.EncryptionPublicKey)
}
