// Written by AI on 2026.11.01 by model gpt-6.1-sol.
// A short-lived stand-in MacBook sender. Each command exits before the real
// receiver runs; fixture state, keys and logins are entirely synthetic.
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/hpke"
	"crypto/x509"
	"fmt"
	"os"
	"path/filepath"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func (p *proof) fixtureWrite(name string, raw []byte) {
	must(os.WriteFile(filepath.Join(p.directory, name), raw, 0600))
}
func (p *proof) fixtureRead(name string) []byte {
	raw, err := os.ReadFile(filepath.Join(p.directory, name))
	must(err)
	return raw
}
func (p *proof) saveCopySender(delivery *ecdsa.PrivateKey) {
	for name, key := range map[string]*ecdsa.PrivateKey{"owner.der": p.signer, "delivery.der": delivery} {
		raw, err := x509.MarshalPKCS8PrivateKey(key)
		must(err)
		p.fixtureWrite(name, raw)
	}
	p.fixtureWrite("config.pb", encoded(p.configuration))
	p.fixtureWrite("keys.pb", encoded(p.keys))
	p.fixtureWrite("relay.pin", p.approver.pin)
}
func (p *proof) copyFixture(action, site string) {
	var delivery *ecdsa.PrivateKey
	if action == "setup" {
		bootstrap := good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetAutomaticKeys{GetAutomaticKeys: &pb.GetAutomaticKeysRequest{}}})).GetAutomaticKeys()
		require(bootstrap != nil && len(bootstrap.SigningPublicKey) == 65, "public keys unavailable before pairing")
		p.pair()
		defer p.work.Close()
		require(proto.Equal(bootstrap, p.pairingAutomaticKeys), "Automatic keys differed from the comparison TLS stream")
		delivery = signingKey()
		set := new(pb.ApproverKeySet)
		must(proto.Unmarshal(p.keys.KeySet, set))
		set.Revision++
		set.Keys = append(set.Keys, &pb.ApproverKey{KeyId: "fixture-copy-delivery", PublicKey: public(delivery), Role: pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY})
		raw := encoded(set)
		p.keys = &pb.SignedApproverKeySet{KeySet: raw, Signature: sign(p.signer, raw), SignerKeyId: p.key.KeyId}
		good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
		keys := good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetAutomaticKeys{GetAutomaticKeys: &pb.GetAutomaticKeysRequest{}}})).GetAutomaticKeys()
		require(proto.Equal(bootstrap, keys), "keys changed during pairing")
		p.configuration.AutomaticKeyId = keys.SigningKeyId
		p.configuration.AutomaticSigningPublicKey = keys.SigningPublicKey
		p.configuration.RelayEncryptionPublicKey = keys.EncryptionPublicKey
		p.configuration.Logins = []*pb.Login{
			{LoginId: "fixture-login", Title: "Dummy Automatic", Sites: []string{site}, Rule: pb.AccessRule_ACCESS_RULE_AUTOMATIC, HasOneTimeCode: true},
			{LoginId: "fixture-ask", Title: "Dummy Ask", Sites: []string{site}, Rule: pb.AccessRule_ACCESS_RULE_ASK},
			{LoginId: "fixture-blocked", Title: "Dummy Blocked", Sites: []string{site}, Rule: pb.AccessRule_ACCESS_RULE_BLOCKED},
		}
		p.publishConfiguration()
	} else {
		readKey := func(name string) *ecdsa.PrivateKey {
			value, err := x509.ParsePKCS8PrivateKey(p.fixtureRead(name))
			must(err)
			return value.(*ecdsa.PrivateKey)
		}
		p.signer, delivery = readKey("owner.der"), readKey("delivery.der")
		p.approver.pin = p.fixtureRead("relay.pin")
		p.configuration = new(pb.Configuration)
		must(proto.Unmarshal(p.fixtureRead("config.pb"), p.configuration))
		p.keys = new(pb.SignedApproverKeySet)
		must(proto.Unmarshal(p.fixtureRead("keys.pb"), p.keys))
		set := new(pb.ApproverKeySet)
		must(proto.Unmarshal(p.keys.KeySet, set))
		p.key = keyInfoFromSet(set, set.RuleOwnerKeyId)
	}
	defer p.saveCopySender(delivery)
	send := func(signed *pb.SignedCopyUpdate) *pb.RelayWireResponse {
		return p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishCopyUpdate{PublishCopyUpdate: signed}})
	}
	if action == "enrol" {
		p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
		defer p.work.Close()
		p.approveEnrolment(p.nextEnrolment(), true)
	}
	if action == "ask" || action == "blocked" || action == "automatic" {
		rule := map[string]pb.AccessRule{"ask": pb.AccessRule_ACCESS_RULE_ASK, "blocked": pb.AccessRule_ACCESS_RULE_BLOCKED, "automatic": pb.AccessRule_ACCESS_RULE_AUTOMATIC}[action]
		p.configuration.Logins[0].Rule = rule
		p.publishConfiguration()
		fmt.Println("PASS configuration committed:", action)
		if action != "automatic" {
			return
		}
	}
	if action == "replay" || action == "resend" || action == "conflict" {
		name := "copy.pb"
		if action == "replay" {
			name = "previous-copy.pb"
		}
		signed := new(pb.SignedCopyUpdate)
		must(proto.Unmarshal(p.fixtureRead(name), signed))
		if action == "conflict" {
			update := new(pb.CopyUpdate)
			must(proto.Unmarshal(signed.Update, update))
			update.Logins[0].Sealed.Ciphertext[0] ^= 1
			signed.Update = encoded(update)
		}
		signed.Signature = sign(delivery, signed.Update)
		response := send(signed)
		if action == "resend" {
			require(good(response).GetPublish().Accepted, "exact resend failed")
		} else {
			require(response.GetError() != nil, "old/conflicting copy accepted")
		}
		fmt.Println("PASS copy", action)
		return
	}
	keys := good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetAutomaticKeys{GetAutomaticKeys: &pb.GetAutomaticKeysRequest{}}})).GetAutomaticKeys()
	require(bytes.Equal(p.configuration.RelayEncryptionPublicKey, keys.EncryptionPublicKey), "relay key changed after restart")
	update := &pb.CopyUpdate{Domain: "agentkeyring.copy-update.v1", DestinationKeyId: keys.EncryptionKeyId, ConfigurationRevision: p.configuration.Revision, Revision: 1}
	if previous, err := os.ReadFile(filepath.Join(p.directory, "copy.pb")); err == nil {
		signed := new(pb.SignedCopyUpdate)
		must(proto.Unmarshal(previous, signed))
		old := new(pb.CopyUpdate)
		must(proto.Unmarshal(signed.Update, old))
		update.Revision = old.Revision + 1
	}
	password := "keyring-r8-dummy-password"
	if action == "update" {
		password = "keyring-r8-updated-password"
	}
	if action != "clear" {
		loginID := "fixture-login"
		if action == "outside" {
			loginID = "outside-configuration"
		}
		if action == "ask-copy" {
			loginID = "fixture-ask"
		}
		if action == "blocked-copy" {
			loginID = "fixture-blocked"
		}
		contents := &pb.AutomaticLoginContents{LoginId: loginID, Sites: []string{site}, Username: "dummy@example.com", Password: password, TotpSeed: []byte("12345678901234567890"), TotpDigits: 6, TotpPeriodSeconds: 30, TotpAlgorithm: "SHA1"}
		receiver, err := ecdh.P256().NewPublicKey(keys.EncryptionPublicKey)
		must(err)
		hpkeKey, err := hpke.NewDHKEMPublicKey(receiver)
		must(err)
		enc, sealer, err := hpke.NewSender(hpkeKey, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(relaycrypto.CopyLoginInfo))
		must(err)
		raw := encoded(contents)
		ciphertext, err := sealer.Seal(relaycrypto.CopyLoginAAD(update.DestinationKeyId, update.ConfigurationRevision, update.Revision, loginID), raw)
		clear(raw)
		must(err)
		update.Logins = []*pb.SealedAutomaticLogin{{LoginId: loginID, Sealed: &pb.SealedBundle{EncapsulatedKey: enc, Ciphertext: ciphertext, ReceiverKeyId: keys.EncryptionKeyId}}}
	}
	if action == "wrong-destination" {
		update.DestinationKeyId = "wrong-destination"
	}
	signed := &pb.SignedCopyUpdate{Update: encoded(update), SignerKeyId: "fixture-copy-delivery"}
	signed.Signature = sign(delivery, signed.Update)
	if action == "bad-signature" {
		signed.Signature[0] ^= 1
	}
	response := send(signed)
	if action == "outside" || action == "ask-copy" || action == "blocked-copy" || action == "wrong-destination" || action == "bad-signature" {
		require(response.GetError().GetCode() == pb.RpcErrorCode_RPC_ERROR_CODE_PERMISSION_DENIED, "invalid copy accepted")
		fmt.Println("PASS refused copy", action)
		return
	}
	require(good(response).GetPublish().Accepted, "copy update failed")
	if previous, err := os.ReadFile(filepath.Join(p.directory, "copy.pb")); err == nil {
		p.fixtureWrite("previous-copy.pb", previous)
	}
	p.fixtureWrite("copy.pb", encoded(signed))
	fmt.Println("PASS copy acknowledged; sender exiting:", action)
}
func keyInfoFromSet(set *pb.ApproverKeySet, id string) *pb.ApproverKey {
	for _, key := range set.Keys {
		if key.KeyId == id {
			return key
		}
	}
	panic("missing owner")
}
