// Written by AI on 2026.11.01 by model gpt-6.1-sol.
// Real relay, Go receiver and APNs transport; synthetic Mac/Face ID keys only.
package main

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/hpke"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/relaycrypto"
	"google.golang.org/protobuf/proto"
)

func (p *proof) copyPhone(label string, delivery *pb.ApproverKey) (wireClient, *pb.ApproverKey, *ecdsa.PrivateKey, *ecdsa.PrivateKey) {
	phone := wireClient{address: p.address, certificate: identity(filepath.Join(p.directory, label)), pin: p.approver.pin}
	signer, encryption := signingKey(), signingKey()
	spki, err := relaycrypto.CertificateSPKI(phone.certificate)
	must(err)
	key := &pb.ApproverKey{KeyId: label, Label: label, PublicKey: public(signer), TlsPublicKey: spki, Role: pb.ApproverRole_APPROVER_ROLE_PHONE, EncryptionPublicKey: public(encryption)}
	pairing := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PairApprover{PairApprover: &pb.PairApproverRequest{Key: key, TlsPublicKey: spki}}})
	defer pairing.Close()
	good(receive(pairing))
	set := new(pb.ApproverKeySet)
	must(proto.Unmarshal(p.keys.KeySet, set))
	set.Revision++
	set.Keys = append(set.Keys, key)
	if delivery != nil {
		set.Keys = append(set.Keys, delivery)
	}
	set.ConfigurationRevision = p.configuration.Revision
	set.ConfigurationSha256 = relaycrypto.Hash(p.signedConfiguration.Configuration)
	// Excluding the phone encryption key cannot authorize its substitution.
	set.PairingTranscriptSha256 = relaycrypto.Hash(relaycrypto.PairTranscript(p.approver.pin, spki, key.PublicKey, p.keys.KeySet))
	wrong := encoded(set)
	require(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: &pb.SignedApproverKeySet{KeySet: wrong, Signature: sign(p.signer, wrong), SignerKeyId: p.key.KeyId}}}).GetError() != nil, "pairing omitted the encryption key")
	set.PairingTranscriptSha256 = relaycrypto.Hash(relaycrypto.PairTranscript(p.approver.pin, spki, key.PublicKey, p.keys.KeySet, key.EncryptionPublicKey))
	raw := encoded(set)
	p.keys = &pb.SignedApproverKeySet{KeySet: raw, Signature: sign(p.signer, raw), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	require(good(receive(pairing)).GetEnrolStatus().State == pb.EnrolState_ENROL_STATE_APPROVED, "phone pairing did not finish")
	return phone, key, signer, encryption
}

func (p *proof) phoneCopyUpdate(key *pb.ApproverKey, signer *ecdsa.PrivateKey, revision uint64, password string) *pb.SignedCopyUpdate {
	destination := relaycrypto.CopyDestinationID(key.EncryptionPublicKey)
	update := &pb.CopyUpdate{Domain: "agentkeyring.copy-update.v1", DestinationKeyId: destination, ConfigurationRevision: p.configuration.Revision, Revision: revision}
	if password != "" {
		contents := &pb.AutomaticLoginContents{LoginId: "fixture-login", Sites: []string{"https://example.com"}, Username: "fixture-user", Password: password}
		receiver, err := ecdh.P256().NewPublicKey(key.EncryptionPublicKey)
		must(err)
		hpkeKey, err := hpke.NewDHKEMPublicKey(receiver)
		must(err)
		enc, sealer, err := hpke.NewSender(hpkeKey, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(relaycrypto.CopyLoginInfo))
		must(err)
		ciphertext, err := sealer.Seal(relaycrypto.CopyLoginAAD(destination, update.ConfigurationRevision, revision, contents.LoginId), encoded(contents))
		must(err)
		update.Logins = []*pb.SealedAutomaticLogin{{LoginId: contents.LoginId, Sealed: &pb.SealedBundle{EncapsulatedKey: enc, Ciphertext: ciphertext, ReceiverKeyId: destination}}}
	}
	raw := encoded(update)
	return &pb.SignedCopyUpdate{Update: raw, Signature: sign(signer, raw), SignerKeyId: "fixture-delivery"}
}

func openPhoneCopy(signed *pb.SignedCopyUpdate, encryption *ecdsa.PrivateKey, deliveryPublic []byte, configuration uint64) *pb.AutomaticLoginContents {
	must(relaycrypto.Verify(deliveryPublic, signed.Update, signed.Signature))
	update := new(pb.CopyUpdate)
	must(proto.Unmarshal(signed.Update, update))
	if update.ConfigurationRevision != configuration || len(update.Logins) == 0 {
		return nil // Stale/missing copies never open; approval-only remains usable.
	}
	private, err := encryption.ECDH()
	must(err)
	openerKey, err := hpke.NewDHKEMPrivateKey(private)
	must(err)
	login := update.Logins[0]
	opener, err := hpke.NewRecipient(login.Sealed.EncapsulatedKey, openerKey, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte(relaycrypto.CopyLoginInfo))
	must(err)
	raw, err := opener.Open(relaycrypto.CopyLoginAAD(update.DestinationKeyId, update.ConfigurationRevision, update.Revision, login.LoginId), login.Sealed.Ciphertext)
	must(err)
	defer clear(raw)
	contents := new(pb.AutomaticLoginContents)
	must(proto.Unmarshal(raw, contents))
	return contents
}

func (p *proof) directPhoneDecision(record []byte, key *pb.ApproverKey, signer *ecdsa.PrivateKey, contents *pb.AutomaticLoginContents) *pb.RelayWireRequest {
	r := p.decision(record, contents == nil)
	signed := r.GetDecide()
	statement := new(pb.DecisionStatement)
	must(proto.Unmarshal(signed.Statement, statement))
	if contents != nil {
		receiver, err := ecdh.P256().NewPublicKey(p.enrolled.ReceiverPublicKey)
		must(err)
		hpkeKey, err := hpke.NewDHKEMPublicKey(receiver)
		must(err)
		enc, sealer, err := hpke.NewSender(hpkeKey, hpke.HKDFSHA256(), hpke.AES256GCM(), []byte("agentkeyring.bundle.v1"))
		must(err)
		bundle := &pb.BundleContents{LeaseId: statement.LeaseId, LoginId: contents.LoginId, Sites: contents.Sites, Username: contents.Username, Password: contents.Password, NotAfterUnixSeconds: statement.NotAfterUnixSeconds}
		ciphertext, err := sealer.Seal(statement.RequestDigest, encoded(bundle))
		must(err)
		signed.Bundle = &pb.SealedBundle{EncapsulatedKey: enc, Ciphertext: ciphertext, ReceiverKeyId: p.enrolled.ReceiverKeyId}
		statement.BundleCiphertextSha256 = relaycrypto.Hash(ciphertext)
	}
	signed.ApproverKeyId = key.KeyId
	signed.Statement = encoded(statement)
	signed.Signature = sign(signer, signed.Statement)
	return r
}

func nextPhoneCopyRequest(stream *tls.Conn, task string) []byte {
	for {
		pending := good(receive(stream)).GetWork().GetRequest()
		if pending != nil {
			record := new(pb.RequestRecord)
			must(proto.Unmarshal(pending.Record, record))
			if record.TaskRef == task {
				return pending.Record
			}
		}
	}
}

func (p *proof) phoneCopyProof() {
	gateway := &pushGateway{key: signingKey()}
	server := httptest.NewUnstartedServer(http.HandlerFunc(gateway.serve))
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	raw, err := x509.MarshalPKCS8PrivateKey(gateway.key)
	must(err)
	keyPath, caPath := filepath.Join(p.directory, "copy-apns.p8"), filepath.Join(p.directory, "copy-apns-ca.pem")
	must(os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: raw}), 0600))
	must(os.WriteFile(caPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600))
	p.extraFlags = []string{"--apns-key", keyPath, "--apns-key-id", "DUMMYKEY01", "--apns-team-id", "DUMMYTEAM1", "--apns-topic", "test.agent-keyring.phone", "--apns-test-gateway", server.URL, "--apns-test-ca", caPath}
	p.start()
	defer p.stop()
	p.pair()
	p.enrol()
	deliverySigner := signingKey()
	deliveryKey := &pb.ApproverKey{KeyId: "fixture-delivery", PublicKey: public(deliverySigner), Role: pb.ApproverRole_APPROVER_ROLE_MAC_DELIVERY}
	phone, phoneKey, phoneSigner, encryption := p.copyPhone("copy-phone", deliveryKey)
	fetch := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_GetCopyUpdate{GetCopyUpdate: &pb.GetCopyUpdateRequest{}}}
	require(phone.call(fetch).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_NOT_FOUND, "missing copy was not explicit")
	require(p.approver.call(fetch).GetError() != nil && p.client.call(fetch).GetError() != nil, "non-phone fetched a copy")
	phoneWork := phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: phoneKey.KeyId}}})
	defer func() { phoneWork.Close() }()
	publish := func(value *pb.SignedCopyUpdate) *pb.RelayWireResponse {
		return p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishCopyUpdate{PublishCopyUpdate: value}})
	}
	copy := p.phoneCopyUpdate(phoneKey, deliverySigner, 1, "dummy-phone-copy-password")
	good(publish(copy))
	require(proto.Equal(copy, good(phone.call(fetch)).GetCopyUpdate()), "copy retrieval changed signed bytes")
	for {
		if value := good(receive(phoneWork)).GetWork().GetCopyUpdate(); value != nil {
			require(proto.Equal(copy, value), "copy watch changed signed bytes")
			break
		}
	}
	copy = p.phoneCopyUpdate(phoneKey, deliverySigner, 2, "dummy-updated-phone-copy-password")
	good(publish(copy))
	for good(receive(phoneWork)).GetWork().GetCopyUpdate() == nil {
	}
	contents := openPhoneCopy(good(phone.call(fetch)).GetCopyUpdate(), encryption, deliveryKey.PublicKey, p.configuration.Revision)
	require(contents.Password == "dummy-updated-phone-copy-password", "password refresh did not reach phone copy")
	for _, mode := range []string{"older", "conflict", "outside", "automatic", "blocked", "wrong-receiver", "signature"} {
		invalid := proto.Clone(copy).(*pb.SignedCopyUpdate)
		update := new(pb.CopyUpdate)
		must(proto.Unmarshal(invalid.Update, update))
		if mode == "older" {
			update.Revision--
		} else if mode != "conflict" {
			update.Revision++
		}
		switch mode {
		case "conflict":
			update.Logins[0].Sealed.Ciphertext[0] ^= 1
		case "outside":
			update.Logins[0].LoginId = "outside"
		case "automatic", "blocked":
			p.configuration.Logins = append(p.configuration.Logins, &pb.Login{LoginId: mode, Rule: map[string]pb.AccessRule{"automatic": pb.AccessRule_ACCESS_RULE_AUTOMATIC, "blocked": pb.AccessRule_ACCESS_RULE_BLOCKED}[mode]})
			p.publishConfiguration()
			update.ConfigurationRevision = p.configuration.Revision
			update.Logins[0].LoginId = mode
		case "wrong-receiver":
			update.Logins[0].Sealed.ReceiverKeyId = "wrong"
		}
		update.ConfigurationRevision = p.configuration.Revision
		invalid.Update, invalid.Signature = encoded(update), nil
		invalid.Signature = sign(deliverySigner, invalid.Update)
		if mode == "signature" {
			invalid.Signature[0] ^= 1
		}
		require(publish(invalid).GetError() != nil, "relay accepted invalid phone copy: "+mode)
	}
	copy = p.phoneCopyUpdate(phoneKey, deliverySigner, 3, "dummy-updated-phone-copy-password")
	good(publish(copy))
	roleCopy := &pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishCopyUpdate{PublishCopyUpdate: copy}}
	require(phone.call(roleCopy).GetError() != nil && p.client.call(roleCopy).GetError() != nil, "phone or receiver published copy authority")
	for _, forbidden := range []*pb.RelayWireRequest{
		{Request: &pb.RelayWireRequest_PublishConfiguration{PublishConfiguration: &pb.ConfigurationPublication{Configuration: p.signedConfiguration}}},
		{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}},
	} {
		require(phone.call(forbidden).GetError() != nil, "phone published configuration or key-set authority")
	}
	contents = openPhoneCopy(copy, encryption, deliveryKey.PublicKey, p.configuration.Revision)
	fmt.Println("PASS encryption key bound into pairing; opaque copy fetch/watch/refresh; replay, scope, receiver and role refusals")
	good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_RegisterPush{RegisterPush: &pb.PushRegistration{ApproverKeyId: phoneKey.KeyId, ApnsDeviceToken: []byte("copy-phone-token")}}}))
	request := leaseRequest("disconnect-request", "disconnect-task", p.enrolled.RecipientId)
	lease := good(p.client.call(request)).GetClient().GetLease()
	record := p.nextRequest()
	decision := p.directPhoneDecision(record, phoneKey, phoneSigner, contents)
	require(phone.call(decision).GetError() != nil, "connected Mac's delay was bypassed")
	p.work.Close()
	require(bytes.Equal(nextPhoneCopyRequest(phoneWork, "disconnect-task"), record), "disconnect changed the pending request")
	firstPush := gateway.waitCount(1)[0]
	require(firstPush.collapse == hex.EncodeToString(relaycrypto.Digest("agentkeyring.request.v1", record)), "disconnect notification has another request")
	require(good(phone.call(decision)).GetDecision().Accepted, "direct phone decision failed")
	openDelivery := func(lease *pb.Lease, scope *pb.RequestLeaseRequest, expectedPassword string) *pb.Delivery {
		response := good(p.client.call(deliverRequest(lease.LeaseId))).GetClient().GetDelivery()
		values, _, err := p.receiverClient(lease, scope).OpenValues(context.Background(), lease, response)
		must(err)
		require(values.Password == expectedPassword, "real receiver opened the wrong phone login")
		values.Password = ""
		return response
	}
	direct := openDelivery(lease, request.GetClient().GetRequestLease(), contents.Password)
	for _, mode := range []string{"missing-signature", "invalid-signature", "delivery-role", "deadline"} {
		altered := proto.Clone(direct).(*pb.Delivery)
		signed := altered.GetSealed().Decision
		switch mode {
		case "missing-signature":
			signed.Signature = nil
		case "invalid-signature":
			signed.Signature[0] ^= 1
		case "delivery-role":
			signed.ApproverKeyId = deliveryKey.KeyId
			signed.Signature = sign(deliverySigner, signed.Statement)
		case "deadline":
			statement := new(pb.DecisionStatement)
			must(proto.Unmarshal(signed.Statement, statement))
			statement.NotAfterUnixSeconds--
			signed.Statement = encoded(statement)
			signed.Signature = sign(phoneSigner, signed.Statement)
		}
		_, _, err := p.receiverClient(lease, request.GetClient().GetRequestLease()).OpenValues(context.Background(), lease, altered)
		require(err != nil, "receiver accepted changed direct phone delivery: "+mode)
	}
	good(p.client.call(endRequest(lease.LeaseId)))
	fmt.Println("PASS connected Mac controls delay; last Mac disconnect immediately wakes phone once; direct phone delivery opens at real receiver")
	request = leaseRequest("lost-phone-request", "lost-phone-task", p.enrolled.RecipientId)
	config, err := relaycrypto.ClientConfig(p.client.certificate, p.client.pin)
	must(err)
	unsent, err := tls.Dial("tcp", p.address, config)
	must(err)
	unsent.Close()                 // Lost before sending any request bytes.
	lost := p.client.open(request) // Lost after commit, observed through phone work.
	record = nextPhoneCopyRequest(phoneWork, "lost-phone-task")
	lost.Close()
	lease = good(p.client.call(request)).GetClient().GetLease()
	require(good(p.client.call(request)).GetClient().GetLease().LeaseId == lease.LeaseId, "retry created another lease")
	decision = p.directPhoneDecision(record, phoneKey, phoneSigner, contents)
	lost = phone.open(decision)
	for deadline := time.Now().Add(5 * time.Second); ; {
		lease = good(p.client.call(clientRequest(&pb.WireRequest{Request: &pb.WireRequest_GetLease{GetLease: &pb.LeaseReference{LeaseId: lease.LeaseId}}}))).GetClient().GetLease()
		if lease.State == pb.LeaseState_LEASE_STATE_ACTIVE {
			break
		}
		require(time.Now().Before(deadline), "phone delivery never committed")
		time.Sleep(10 * time.Millisecond)
	}
	lost.Close()
	sealed := openDelivery(lease, request.GetClient().GetRequestLease(), contents.Password)
	gateway.waitCount(2)
	p.stop()
	p.start()
	ack := good(phone.call(decision)).GetDecision()
	require(ack.Accepted && proto.Equal(ack.Lease, lease), "lost acknowledgement changed lease or deadline")
	require(proto.Equal(copy, good(phone.call(fetch)).GetCopyUpdate()), "restart lost opaque phone copy")
	require(proto.Equal(sealed, openDelivery(lease, request.GetClient().GetRequestLease(), contents.Password)), "restart changed sealed phone delivery")
	good(p.client.call(endRequest(lease.LeaseId)))
	require(good(phone.call(decision)).GetDecision().Lease.State == pb.LeaseState_LEASE_STATE_RELEASED, "late retry reopened released lease")
	require(gateway.count() == 2, "lost replies or restart duplicated notification")
	phoneWork.Close()
	phoneWork = phone.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: phoneKey.KeyId}}})
	p.work = p.approver.open(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_WatchWork{WatchWork: &pb.WatchWorkRequest{ApproverKeyId: p.key.KeyId}}})
	defer p.work.Close()
	fmt.Println("PASS lost requests before/after send rejoin one lease; lost phone ACK and SIGKILL retain exact copy, decision, deadline and delivery")
	for _, mode := range []string{"stale", "missing"} {
		p.configuration.MirrorRefreshedUnixSeconds++
		p.publishConfiguration()
		if mode == "missing" {
			copy = p.phoneCopyUpdate(phoneKey, deliverySigner, 4, "")
			good(publish(copy))
		}
		require(openPhoneCopy(good(phone.call(fetch)).GetCopyUpdate(), encryption, deliveryKey.PublicKey, p.configuration.Revision) == nil, "stale/missing copy opened")
		r := leaseRequest(mode, mode, p.enrolled.RecipientId)
		l := good(p.client.call(r)).GetClient().GetLease()
		record := p.nextRequest()
		good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: l.LeaseId, Record: record}}}))
		answer := phoneAnswer(record, phoneSigner, phoneKey.KeyId, "", false)
		require(good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_AnswerFromPhone{AnswerFromPhone: answer}})).GetDecision().Accepted, "approval-only fallback refused")
		p.nextPhoneAnswer(answer)
		require(good(p.approver.call(p.phoneDelivery(record, answer, deliverySigner))).GetDecision().Accepted, "Mac fallback failed")
		openDelivery(l, r.GetClient().GetRequestLease(), "fixture-password-for-relay-system-proof")
		good(p.client.call(endRequest(l.LeaseId)))
	}
	fmt.Println("PASS stale and missing phone copies use signed approval-only fallback; awake Mac delivers on original lease")
	copy = p.phoneCopyUpdate(phoneKey, deliverySigner, 5, "dummy-updated-phone-copy-password")
	good(publish(copy))
	contents = openPhoneCopy(copy, encryption, deliveryKey.PublicKey, p.configuration.Revision)
	for _, winner := range []string{"phone", "Mac", "concurrent"} {
		r := leaseRequest(winner, winner, p.enrolled.RecipientId)
		l := good(p.client.call(r)).GetClient().GetLease()
		record := p.nextRequest()
		good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: l.LeaseId, Record: record}}}))
		mobile, mac := p.directPhoneDecision(record, phoneKey, phoneSigner, contents), p.decision(record, false)
		var a, b *pb.DecisionAck
		if winner == "concurrent" {
			results := make(chan *pb.DecisionAck, 2)
			go func() { results <- good(phone.call(mobile)).GetDecision() }()
			go func() { results <- good(p.approver.call(mac)).GetDecision() }()
			a, b = <-results, <-results
		} else if winner == "phone" {
			a, b = good(phone.call(mobile)).GetDecision(), good(p.approver.call(mac)).GetDecision()
		} else {
			a, b = good(p.approver.call(mac)).GetDecision(), good(phone.call(mobile)).GetDecision()
		}
		require(a.Accepted != b.Accepted && a.Lease.LeaseId == b.Lease.LeaseId && proto.Equal(a.Lease, b.Lease), "racing decisions both won or changed lease")
		good(p.client.call(endRequest(l.LeaseId)))
	}
	fmt.Println("PASS Mac-first, phone-first and concurrent answers commit exactly one decision and return the same lease")
	for _, mode := range []string{"plain", "reply"} {
		r := leaseRequest("direct-denial-"+mode, "direct-denial-"+mode, p.enrolled.RecipientId)
		l := good(p.client.call(r)).GetClient().GetLease()
		record := p.nextRequest()
		good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: l.LeaseId, Record: record}}}))
		denial := p.directPhoneDecision(record, phoneKey, phoneSigner, nil)
		if mode == "plain" {
			signed := denial.GetDecide()
			statement := new(pb.DecisionStatement)
			must(proto.Unmarshal(signed.Statement, statement))
			statement.Authority = pb.DecisionAuthority_DECISION_AUTHORITY_APPROVER_CONNECTION
			statement.ReplySha256 = relaycrypto.Hash(nil)
			signed.Statement, signed.Signature, signed.Reply = encoded(statement), nil, ""
		}
		ack := good(phone.call(denial)).GetDecision()
		require(ack.Accepted && ack.Lease.State == pb.LeaseState_LEASE_STATE_DENIED && ack.Lease.ApprovedBy == pb.ApprovedBy_APPROVED_BY_IPHONE, "direct denial lost phone attribution")
		view, err := p.receiverClient(l, r.GetClient().GetRequestLease()).Authority().Lease(context.Background(), l.LeaseId)
		must(err)
		require(view.Reply == denial.GetDecide().Reply && (mode == "plain") == (view.SignedDenial == nil), "receiver did not verify direct phone denial reply")
		good(phone.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_ClearDenial{ClearDenial: &pb.ClearDenialRequest{RecipientId: p.enrolled.RecipientId, LoginId: "fixture-login"}}}))
	}
	fmt.Println("PASS unsigned plain phone Deny and signed reply Deny are terminal, attributed to iPhone, and verified at receiver")
	// Current Blocked policy and revocation still defeat a previously signed phone answer.
	r := leaseRequest("blocked-after-copy", "blocked-after-copy", p.enrolled.RecipientId)
	l := good(p.client.call(r)).GetClient().GetLease()
	record = p.nextRequest()
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_EscalateToPhone{EscalateToPhone: &pb.PhoneEscalation{LeaseId: l.LeaseId, Record: record}}}))
	late := p.directPhoneDecision(record, phoneKey, phoneSigner, contents)
	p.configuration.Logins[0].Rule = pb.AccessRule_ACCESS_RULE_BLOCKED
	p.publishConfiguration()
	require(!good(phone.call(late)).GetDecision().Accepted, "old phone copy defeated Blocked")
	p.configuration.Logins[0].Rule = pb.AccessRule_ACCESS_RULE_ASK
	p.publishConfiguration()
	other, otherKey, _, _ := p.copyPhone("replacement-copy-phone", nil)
	require(other.call(fetch).GetError().Code == pb.RpcErrorCode_RPC_ERROR_CODE_NOT_FOUND, "second phone fetched another phone's copy")
	set := new(pb.ApproverKeySet)
	must(proto.Unmarshal(p.keys.KeySet, set))
	set.Revision++
	var retained []*pb.ApproverKey
	for _, key := range set.Keys {
		if key.KeyId != phoneKey.KeyId {
			retained = append(retained, key)
		}
	}
	set.Keys = retained
	keyset := encoded(set)
	p.keys = &pb.SignedApproverKeySet{KeySet: keyset, Signature: sign(p.signer, keyset), SignerKeyId: p.key.KeyId}
	good(p.approver.call(&pb.RelayWireRequest{Request: &pb.RelayWireRequest_PublishApproverKeys{PublishApproverKeys: p.keys}}))
	require(phone.call(fetch).GetError() != nil && publish(copy).GetError() != nil, "retired phone still accessed its copy")
	good(publish(p.phoneCopyUpdate(otherKey, deliverySigner, 1, "replacement-phone-password")))
	require(good(other.call(fetch)).GetCopyUpdate() != nil, "replacement phone did not get a fresh copy")
	fmt.Println("PASS current Blocked refuses an older phone answer; replacement phone cannot fetch old copy; retired phone loses access")
}
