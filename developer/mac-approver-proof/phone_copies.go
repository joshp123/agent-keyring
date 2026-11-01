// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hpke"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

type copyPhone struct {
	client
	key    *pb.ApproverKey
	opener *ecdh.PrivateKey
	keySet *pb.SignedApproverKeySet
}

func (p *proof) pairCopyPhone(label string) *copyPhone {
	phone := &copyPhone{client: client{address: p.receiver.address, cert: identity()}}
	signer, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	must(err)
	public := elliptic.Marshal(elliptic.P256(), signer.X, signer.Y)
	phone.opener, err = ecdh.P256().GenerateKey(rand.Reader)
	must(err)
	spki, err := relaycrypto.CertificateSPKI(phone.cert)
	must(err)
	phone.key = &pb.ApproverKey{KeyId: relaycrypto.CopyDestinationID(public), PublicKey: public,
		TlsPublicKey: spki, Label: label, Role: pb.ApproverRole_APPROVER_ROLE_PHONE,
		EncryptionPublicKey: phone.opener.PublicKey().Bytes()}
	stream := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{Key: phone.key, TlsPublicKey: spki}}})
	defer stream.Close()
	pending := receive(stream).GetEnrolStatus()
	require(pending.State == pb.EnrolState_ENROL_STATE_PENDING, "phone activated before comparison")
	phone.pin = stream.ConnectionState().PeerCertificates[0].RawSubjectPublicKeyInfo
	transcript := relaycrypto.PairTranscript(phone.pin, spki, public, pending.ApproverKeySet.KeySet, phone.key.EncryptionPublicKey)
	fingerprint := relaycrypto.Fingerprint(transcript)
	work := p.owner.wait(func(e []string) bool { return e[0] == "APPROVER" && e[1] == phone.key.KeyId })
	require(work[2] == fingerprint, "Swift/Go pairing did not compare the phone's sealing key")
	p.owner.status()
	before := p.owner.authorizations
	legacy := relaycrypto.Fingerprint(relaycrypto.PairTranscript(phone.pin, spki, public, pending.ApproverKeySet.KeySet))
	p.owner.expectFailure("confirm-approver", phone.key.KeyId, legacy)
	p.owner.status()
	require(p.owner.authorizations == before, "wrong comparison requested authorization")
	p.owner.action("confirm-approver", phone.key.KeyId, fingerprint)
	approved := receive(stream).GetEnrolStatus()
	require(approved.State == pb.EnrolState_ENROL_STATE_APPROVED, "copy phone was not paired")
	phone.keySet = approved.ApproverKeySet
	var previous, next pb.ApproverKeySet
	must(proto.Unmarshal(pending.ApproverKeySet.KeySet, &previous))
	must(proto.Unmarshal(phone.keySet.KeySet, &next))
	must(relaycrypto.Verify(previous.Keys[0].PublicKey, phone.keySet.KeySet, phone.keySet.Signature))
	require(bytes.Equal(next.PairingTranscriptSha256, relaycrypto.Hash(transcript)), "signed key set did not bind the comparison")
	found := false
	for _, key := range next.Keys {
		found = found || proto.Equal(key, phone.key)
	}
	require(found, "signed key set omitted the phone's sealing key")
	p.waitApplied()
	require(p.owner.authorizations == before+1, "phone pairing plus first copy required another authorization")
	fmt.Println("PASS Swift/Go comparison and signed key set bind the sealing key; pairing and first Ask copy use one authorization")
	return phone
}

func (p *copyPhone) copy() *pb.SignedCopyUpdate {
	return p.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetCopyUpdate{GetCopyUpdate: &pb.GetCopyUpdateRequest{}}}).GetCopyUpdate()
}

func (p *copyPhone) checkCopy(signed *pb.SignedCopyUpdate, password string, wantLogin bool) *pb.CopyUpdate {
	require(signed != nil, "phone copy is missing")
	var keys pb.ApproverKeySet
	must(proto.Unmarshal(p.keySet.KeySet, &keys))
	var signer []byte
	for _, key := range keys.Keys {
		if key.KeyId == signed.SignerKeyId && key.Role == pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY {
			signer = key.PublicKey
		}
	}
	require(signer != nil, "phone copy was not signed by the trusted Mac delivery key")
	must(relaycrypto.Verify(signer, signed.Update, signed.Signature))
	var update pb.CopyUpdate
	must(proto.Unmarshal(signed.Update, &update))
	configuration := p.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
	must(relaycrypto.Verify(keys.Keys[0].PublicKey, configuration.Configuration, configuration.Signature))
	var contents pb.Configuration
	must(proto.Unmarshal(configuration.Configuration, &contents))
	require(len(contents.Logins) == 3, "dummy refresh lost the other two logins")
	require(update.Domain == "agentkeyring.copy-update.v1" && update.DestinationKeyId == relaycrypto.CopyDestinationID(p.key.EncryptionPublicKey), "wrong copy destination or domain")
	require(update.ConfigurationRevision == contents.Revision, "phone copy belongs to an old configuration")
	if !wantLogin {
		require(len(update.Logins) == 0, "phone retained a non-Ask login")
		return &update
	}
	require(len(update.Logins) == 1 && update.Logins[0].LoginId == loginID, "phone copy contains Automatic or Blocked logins")
	var login *pb.Login
	for _, candidate := range contents.Logins {
		if candidate.LoginId == loginID {
			login = candidate
		}
	}
	require(login != nil && login.Rule == pb.AccessRule_ACCESS_RULE_ASK, "phone copy login is not currently Ask")
	sealed := update.Logins[0].Sealed
	require(sealed.ReceiverKeyId == update.DestinationKeyId, "envelope receiver differs")
	private, err := hpke.NewDHKEMPrivateKey(p.opener)
	must(err)
	opener, err := hpke.NewRecipient(sealed.EncapsulatedKey, private, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(relaycrypto.CopyLoginInfo))
	must(err)
	plain, err := opener.Open(relaycrypto.CopyLoginAAD(update.DestinationKeyId, update.ConfigurationRevision, update.Revision, loginID), sealed.Ciphertext)
	must(err)
	var credential pb.AutomaticLoginContents
	must(proto.Unmarshal(plain, &credential))
	clear(plain)
	require(credential.LoginId == loginID && credential.Username == login.Account && credential.Password == password, "opened phone credential differs")
	require(proto.Equal(&pb.Login{Sites: credential.Sites}, &pb.Login{Sites: login.Sites}), "opened phone destinations differ")
	require(string(credential.TotpSeed) == "12345678901234567890" && credential.TotpPeriodSeconds == 30 && credential.TotpDigits == 6 && credential.TotpAlgorithm == "SHA1", "phone copy lost TOTP contents")
	return &update
}

func (p *proof) runPhoneCopyUpdates() {
	p.startRelay()
	defer p.stopRelay()
	network := &approvalNetwork{target: "127.0.0.1:17445", address: "127.0.0.1:17455"}
	network.up()
	defer network.down()
	p.approverPort = "17455"
	p.owner = startOwner(p.fixture, p.root)
	defer func() { p.owner.stop() }()
	p.owner.action("mixed-rules")
	p.pair()
	p.enrol()
	p.waitApplied()
	phone := p.pairCopyPhone("Dummy copy phone")
	initial := phone.copy()
	first := phone.checkCopy(initial, "example-password", true)
	watch := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: phone.key.KeyId}}})
	defer watch.Close()
	for {
		if copy := receive(watch).GetWork().GetCopyUpdate(); copy != nil {
			require(proto.Equal(copy, initial), "WatchWork backlog changed the retained signed copy")
			break
		}
	}
	fmt.Println("PASS real relay fetch and WatchWork backlog retain the exact Swift-signed Ask-only password/TOTP copy; Automatic and Blocked are excluded")
	p.owner.status()
	authorizations, signatures := p.owner.authorizations, p.owner.backgroundSignatures
	configuration := phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()
	network.Lock()
	network.loseReply, network.passNewCalls = true, 1 // ACK the mini copy; lose the phone-copy ACK.
	network.Unlock()
	p.owner.action("refresh", "refreshed-phone-password")
	for deadline := time.Now().Add(15 * time.Second); ; {
		network.Lock()
		dropped := network.dropped
		network.Unlock()
		if dropped > 0 {
			break
		}
		require(time.Now().Before(deadline), "phone copy acknowledgement was not lost")
		time.Sleep(50 * time.Millisecond)
	}
	refreshed := phone.copy()
	second := phone.checkCopy(refreshed, "refreshed-phone-password", true)
	require(second.Revision == first.Revision+1, "password refresh did not advance the phone destination counter")
	require(proto.Equal(configuration, phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetConfiguration{GetConfiguration: &pb.GetConfigurationRequest{}}}).GetConfiguration()), "password-only refresh republished configuration")
	p.owner.action("saved")
	p.owner.status()
	require(p.owner.applying && p.owner.authorizations == authorizations, "lost copy ACK cleared Applying or refresh requested authorization")
	require(p.owner.backgroundSignatures == signatures+2, "refresh did not sign exactly one update per destination")
	require(len(p.owner.copies) == 1, "expected only the phone update to remain unacknowledged")
	var id, exact string
	for id, exact = range p.owner.copies {
	}
	bytes, err := hex.DecodeString(exact)
	must(err)
	var command pb.RelayWireRequest
	must(proto.Unmarshal(bytes, &command))
	require(proto.Equal(command.GetPublishCopyUpdate(), refreshed), "outbox did not retain the accepted phone copy")
	fmt.Println("PASS production Swift import refreshes the phone copy without authorization or configuration change; Applying waits for its ACK")
	p.owner.stop()
	p.stopRelay()
	network.Lock()
	network.loseReply, network.pauseNewCalls = false, true
	network.Unlock()
	p.startRelay()
	p.owner = startOwner(p.fixture, p.root)
	p.owner.action("saved")
	p.owner.status()
	require(p.owner.copies[id] == exact && p.owner.applying, "Mac restart changed the signed phone copy or lost Applying")
	require(p.owner.authorizations == authorizations && p.owner.backgroundSignatures == signatures+2, "restart repeated authorization or encryption/signing")
	require(proto.Equal(phone.copy(), refreshed), "relay restart changed the retained copy")
	network.Lock()
	network.pauseNewCalls = false
	network.Unlock()
	p.waitApplied()
	p.owner.status()
	require(p.owner.authorizations == authorizations && p.owner.backgroundSignatures == signatures+2, "exact resend needed another authorization or signature")
	fmt.Println("PASS lost ACK plus Mac/relay restarts resend exact signed ciphertext once; no additional touch or signature")
	previous := second.Revision
	for _, rule := range []string{"auto", "ask", "block"} {
		p.owner.action("rule", rule)
		p.waitApplied()
		update := phone.checkCopy(phone.copy(), "refreshed-phone-password", rule == "ask")
		require(update.Revision == previous+1, "configuration change reset the phone destination counter")
		previous = update.Revision
	}
	fmt.Println("PASS Ask→Automatic removes the phone copy, Automatic→Ask restores its current password, and Blocked clears it; revisions persist across configurations")
	p.owner.status()
	before := p.owner.backgroundSignatures
	p.addApprover()
	p.waitApplied()
	require(p.owner.backgroundSignatures == before, "approval-only phone was sent a password copy")
	fmt.Println("PASS legacy approval-only phone keeps the old comparison transcript and receives no login copy")
	fmt.Println("ALL SWIFT MAC PHONE COPY PROOFS PASSED")
}
