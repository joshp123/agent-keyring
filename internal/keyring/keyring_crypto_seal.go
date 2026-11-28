// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// Package keyring holds the sealed formats and signed documents of
// proto/agentkeyring/v2/keyring.proto, as the relay and the command use them.
// The apps have the same in Swift (AgentKeyringSealing). The device half
// (sealing, approving and denying) is here so a software key can stand in for a chip in
// end-to-end tests.
package keyring

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/hpke"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"slices"
	"strconv"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"google.golang.org/protobuf/proto"
)

const (
	MembersDomain   = "agentkeyring.members.v2"
	CatalogueDomain = "agentkeyring.catalogue.v2"
	RequestDomain   = "agentkeyring.request.v2"
	AnswerDomain    = "agentkeyring.answer.v2"
	SealedDomain    = "agentkeyring.sealed.v2"
	PushDomain      = "agentkeyring.push.v2"
	EndDomain       = "agentkeyring.end.v2"
	FreshDomain     = "agentkeyring.fresh.v2"
	ApprovalSeconds = 1800
)

var (
	loginInfo    = []byte("agentkeyring.login.v2")
	deliveryInfo = []byte("agentkeyring.delivery.v2")
	noticeInfo   = []byte("agentkeyring.notice.v2")
	pushKeyInfo  = []byte("agentkeyring.push-credential.v2")

	ErrWrongDomain   = errors.New("not the expected kind of document")
	ErrUnknownSigner = errors.New("signed by a key that is not one of the devices")
	ErrBadSignature  = errors.New("signature does not match")
	ErrNotAllowed    = errors.New("this device's key may not sign this")
	ErrStale         = errors.New("not newer than the revision already held")
	ErrMismatch      = errors.New("does not belong to this request")
	ErrExpired       = errors.New("approval has expired")
)

// DeriveKeyID is lowercase hex SHA-256 of public key bytes.
func DeriveKeyID(publicKey []byte) string {
	sum := sha256.Sum256(publicKey)
	return hex.EncodeToString(sum[:])
}

func ComputeSHA256(data []byte) []byte { sum := sha256.Sum256(data); return sum[:] }

func keyringHPKESuite() hpke.AEAD { return hpke.AES256GCM() }

func lengthPrefixed(parts ...string) []byte {
	var out []byte
	for _, part := range parts {
		out = binary.BigEndian.AppendUint32(out, uint32(len(part)))
		out = append(out, part...)
	}
	return out
}

func sealKeyringPayload(publicKey, info, aad, plaintext []byte) (enc, ciphertext []byte, err error) {
	point, err := ecdh.P256().NewPublicKey(publicKey)
	if err != nil {
		return nil, nil, err
	}
	key, err := hpke.NewDHKEMPublicKey(point)
	if err != nil {
		return nil, nil, err
	}
	enc, sender, err := hpke.NewSender(key, hpke.HKDFSHA256(), keyringHPKESuite(), info)
	if err != nil {
		return nil, nil, err
	}
	ciphertext, err = sender.Seal(aad, plaintext)
	return enc, ciphertext, err
}

func openKeyringPayload(private *ecdh.PrivateKey, info, enc, aad, ciphertext []byte) ([]byte, error) {
	key, err := hpke.NewDHKEMPrivateKey(private)
	if err != nil {
		return nil, err
	}
	recipient, err := hpke.NewRecipient(enc, key, hpke.HKDFSHA256(), keyringHPKESuite(), info)
	if err != nil {
		return nil, err
	}
	return recipient.Open(aad, ciphertext)
}

// SealLogin seals one login to a device's opening key or a machine's receiving
// key, signed by the sealing device's reply key (replyKeyID, sign). version is
// the secret's import (Login.version): a reseal keeps the opened copy's.
func SealLogin(secret *pb.LoginSecret, version uint64, publicKey []byte, openerID, replyKeyID string, sign PayloadSigner) (*pb.SealedLogin, error) {
	plaintext, err := proto.Marshal(secret)
	if err != nil {
		return nil, err
	}
	enc, ciphertext, err := sealKeyringPayload(publicKey, loginInfo, lengthPrefixed(openerID, secret.LoginId), plaintext)
	if err != nil {
		return nil, err
	}
	sealed := &pb.SealedLogin{LoginId: secret.LoginId, OpenerId: openerID, EncapsulatedKey: enc, Ciphertext: ciphertext, SignerKeyId: replyKeyID, Version: version}
	if sealed.Signature, err = sign(sealedMessage(sealed)); err != nil {
		return nil, err
	}
	return sealed, nil
}

func sealedMessage(sealed *pb.SealedLogin) []byte {
	message := lengthPrefixed(SealedDomain, sealed.LoginId, sealed.OpenerId, string(sealed.EncapsulatedKey), string(sealed.Ciphertext))
	return binary.BigEndian.AppendUint64(message, sealed.Version)
}

// VerifySealedLogin accepts a sealed copy of the login the signed catalogue lists
// only if a device in members signed it and it is the catalogue's version, so
// a relay can neither make one up, relabel one, nor serve an older one. A
// login listed at version 0 has no copy anywhere: its password was deleted
// when it was Blocked.
func VerifySealedLogin(sealed *pb.SealedLogin, members *pb.Members, listed *pb.Login) error {
	if listed == nil || sealed.LoginId != listed.LoginId || sealed.Version != listed.Version || listed.Version == 0 {
		return ErrMismatch
	}
	_, err := VerifySignedDocument(&pb.Signed{Payload: sealedMessage(sealed), SignerKeyId: sealed.SignerKeyId, Signature: sealed.Signature}, members, true)
	return err
}

// VerifyOpenedLoginBinding accepts an opened login only if it was sealed as the login it is
// used for: the same name, sites and account.
func VerifyOpenedLoginBinding(secret *pb.LoginSecret, login *pb.Login) error {
	if login == nil || secret.Title != login.Title || secret.Username != login.Account || !slices.Equal(secret.Sites, login.Sites) {
		return ErrMismatch
	}
	return nil
}

func OpenSealedLogin(sealed *pb.SealedLogin, private *ecdh.PrivateKey) (*pb.LoginSecret, error) {
	plaintext, err := openKeyringPayload(private, loginInfo, sealed.EncapsulatedKey, lengthPrefixed(sealed.OpenerId, sealed.LoginId), sealed.Ciphertext)
	if err != nil {
		return nil, err
	}
	secret := &pb.LoginSecret{}
	if err := proto.Unmarshal(plaintext, secret); err != nil {
		return nil, err
	}
	if secret.LoginId != sealed.LoginId {
		return nil, ErrMismatch
	}
	return secret, nil
}

// SealNotice encrypts the signed request envelope to the device's notice key.
func SealNotice(envelope *pb.SignedRequestEnvelope, noticeKey []byte, deviceKeyID string) (*pb.Notice, error) {
	plaintext, err := proto.Marshal(envelope)
	if err != nil {
		return nil, err
	}
	enc, ciphertext, err := sealKeyringPayload(noticeKey, noticeInfo, []byte(deviceKeyID), plaintext)
	if err != nil {
		return nil, err
	}
	return &pb.Notice{EncapsulatedKey: enc, Ciphertext: ciphertext}, nil
}

func OpenNotice(notice *pb.Notice, private *ecdh.PrivateKey, deviceKeyID string) (*pb.SignedRequestEnvelope, error) {
	plaintext, err := openKeyringPayload(private, noticeInfo, notice.EncapsulatedKey, []byte(deviceKeyID), notice.Ciphertext)
	if err != nil {
		return nil, err
	}
	envelope := &pb.SignedRequestEnvelope{}
	return envelope, proto.Unmarshal(plaintext, envelope)
}

// SealPushCredential seals Apple's push credential to one machine's receiving key.
func SealPushCredential(credential *pb.PushCredential, receivingKey []byte, machineID string) (*pb.SealedPushCredential, error) {
	plaintext, err := proto.Marshal(credential)
	if err != nil {
		return nil, err
	}
	enc, ciphertext, err := sealKeyringPayload(receivingKey, pushKeyInfo, []byte(machineID), plaintext)
	if err != nil {
		return nil, err
	}
	return &pb.SealedPushCredential{OpenerId: machineID, EncapsulatedKey: enc, Ciphertext: ciphertext}, nil
}

func OpenPushCredential(sealed *pb.SealedPushCredential, private *ecdh.PrivateKey) (*pb.PushCredential, error) {
	plaintext, err := openKeyringPayload(private, pushKeyInfo, sealed.EncapsulatedKey, []byte(sealed.OpenerId), sealed.Ciphertext)
	if err != nil {
		return nil, err
	}
	credential := &pb.PushCredential{}
	return credential, proto.Unmarshal(plaintext, credential)
}

// SignRequest is the asking machine's request, signed with its TLS key.
func SignRequest(request *pb.Request, sign PayloadSigner) (*pb.Signed, error) {
	payload, err := proto.Marshal(request)
	if err != nil {
		return nil, err
	}
	return SignKeyringDocument(payload, request.MachineId, sign)
}

// VerifySignedLeaseRequest accepts a request only if the machine it names in members
// signed it with its TLS key, so a relay can neither make one up nor send an
// answer to another machine.
func VerifySignedLeaseRequest(requestBytes, signature []byte, members *pb.Members) (*pb.Request, *pb.Machine, error) {
	request, err := ParseLeaseRequestPayload(requestBytes)
	if err != nil {
		return nil, nil, err
	}
	index := slices.IndexFunc(members.GetMachines(), func(m *pb.Machine) bool { return m.MachineId == request.MachineId })
	if index < 0 {
		return nil, nil, ErrUnknownSigner
	}
	machine := members.Machines[index]
	key, err := x509.ParsePKIXPublicKey(machine.TlsPublicKey)
	public, ok := key.(*ecdsa.PublicKey)
	if err != nil || !ok || !ecdsa.VerifyASN1(public, ComputeSHA256(requestBytes), signature) {
		return nil, nil, ErrBadSignature
	}
	return request, machine, nil
}

// ParseLeaseRequestPayload reads Request bytes and checks their domain.
func ParseLeaseRequestPayload(data []byte) (*pb.Request, error) {
	request := &pb.Request{}
	if err := proto.Unmarshal(data, request); err != nil {
		return nil, err
	}
	if request.Domain != RequestDomain {
		return nil, ErrWrongDomain
	}
	return request, nil
}

// PayloadSigner signs payload bytes, returning a DER ECDSA P-256 signature over SHA-256.
type PayloadSigner func(payload []byte) ([]byte, error)

// NewSoftwarePayloadSigner signs with a software key, standing in for a chip in tests.
func NewSoftwarePayloadSigner(key *ecdsa.PrivateKey) PayloadSigner {
	return func(payload []byte) ([]byte, error) { return ecdsa.SignASN1(rand.Reader, key, ComputeSHA256(payload)) }
}

func SignKeyringDocument(payload []byte, signerKeyID string, sign PayloadSigner) (*pb.Signed, error) {
	signature, err := sign(payload)
	if err != nil {
		return nil, err
	}
	return &pb.Signed{Payload: payload, Signature: signature, SignerKeyId: signerKeyID}, nil
}

// BuildSignedApproval is what a device sends to approve: the opened login sealed again for
// the asking machine for 30 minutes, with an answer it signs.
func BuildSignedApproval(requestBytes []byte, secret *pb.LoginSecret, sites []string, receivingKey []byte, signerKeyID string, sign PayloadSigner, now time.Time) (*pb.AnswerUpload, error) {
	request, err := ParseLeaseRequestPayload(requestBytes)
	if err != nil {
		return nil, err
	}
	if request.LoginId != secret.LoginId {
		return nil, ErrMismatch
	}
	requestHash := ComputeSHA256(requestBytes)
	decided := now.Unix()
	codes, err := GenerateTOTPCodes(secret, decided, decided+ApprovalSeconds)
	if err != nil {
		return nil, err
	}
	contents, err := proto.Marshal(&pb.DeliveryContents{RequestId: request.RequestId, LoginId: secret.LoginId, Sites: sites,
		Username: secret.Username, Password: secret.Password, OneTimeCodes: codes, NotAfterUnixSeconds: decided + ApprovalSeconds})
	if err != nil {
		return nil, err
	}
	enc, ciphertext, err := sealKeyringPayload(receivingKey, deliveryInfo, requestHash, contents)
	if err != nil {
		return nil, err
	}
	answer, err := proto.Marshal(&pb.Answer{Domain: AnswerDomain, RequestSha256: requestHash, Choice: pb.Choice_CHOICE_APPROVE,
		DecidedUnixSeconds: decided, NotAfterUnixSeconds: decided + ApprovalSeconds, DeliverySha256: ComputeSHA256(ciphertext)})
	if err != nil {
		return nil, err
	}
	signed, err := SignKeyringDocument(answer, signerKeyID, sign)
	if err != nil {
		return nil, err
	}
	return &pb.AnswerUpload{Answer: signed, Delivery: &pb.Delivery{EncapsulatedKey: enc, Ciphertext: ciphertext}}, nil
}

// BuildSignedDenial denies with words, signed with the device's signing key or reply key.
func BuildSignedDenial(requestBytes []byte, reply, signerKeyID string, sign PayloadSigner, now time.Time) (*pb.AnswerUpload, error) {
	if _, err := ParseLeaseRequestPayload(requestBytes); err != nil {
		return nil, err
	}
	answer, err := proto.Marshal(&pb.Answer{Domain: AnswerDomain, RequestSha256: ComputeSHA256(requestBytes), Choice: pb.Choice_CHOICE_DENY,
		DecidedUnixSeconds: now.Unix(), Reply: reply})
	if err != nil {
		return nil, err
	}
	signed, err := SignKeyringDocument(answer, signerKeyID, sign)
	if err != nil {
		return nil, err
	}
	return &pb.AnswerUpload{Answer: signed}, nil
}

// VerifySignedDocument checks a signature against a device in members and returns it. A
// reply key is accepted only when allowReplyKey: on a denial.
func VerifySignedDocument(signed *pb.Signed, members *pb.Members, allowReplyKey bool) (*pb.Device, error) {
	var device *pb.Device
	var key []byte
	for _, candidate := range members.Devices {
		switch {
		case candidate.KeyId == signed.SignerKeyId:
			device, key = candidate, candidate.SigningPublicKey
		case candidate.ReplyKeyId != "" && candidate.ReplyKeyId == signed.SignerKeyId:
			if !allowReplyKey {
				return nil, ErrNotAllowed
			}
			device, key = candidate, candidate.ReplyPublicKey
		}
	}
	if device == nil {
		return nil, ErrUnknownSigner
	}
	// The key ID is the key's own hash: a list may not pair a device's ID with another key.
	if DeriveKeyID(key) != signed.SignerKeyId {
		return nil, ErrBadSignature
	}
	public, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), key)
	if err != nil || !ecdsa.VerifyASN1(public, ComputeSHA256(signed.Payload), signed.Signature) {
		return nil, ErrBadSignature
	}
	return device, nil
}

// VerifyRequestAnswer returns the answer in an approval once its signer and request are checked.
func VerifyRequestAnswer(approval *pb.Approval, members *pb.Members) (*pb.Answer, *pb.Device, error) {
	answer := &pb.Answer{}
	if err := proto.Unmarshal(approval.GetAnswer().GetPayload(), answer); err != nil {
		return nil, nil, err
	}
	if answer.Domain != AnswerDomain {
		return nil, nil, ErrWrongDomain
	}
	device, err := VerifySignedDocument(approval.Answer, members, answer.Choice == pb.Choice_CHOICE_DENY)
	if err != nil {
		return nil, nil, err
	}
	if !bytes.Equal(answer.RequestSha256, ComputeSHA256(approval.Request)) {
		return nil, nil, ErrMismatch
	}
	return answer, device, nil
}

// OpenApprovedCredential checks an approval and opens its delivery with the machine's receiving key.
func OpenApprovedCredential(approval *pb.Approval, members *pb.Members, receiving *ecdh.PrivateKey, now time.Time) (*pb.DeliveryContents, error) {
	answer, _, err := VerifyRequestAnswer(approval, members)
	if err != nil {
		return nil, err
	}
	if answer.Choice != pb.Choice_CHOICE_APPROVE || !bytes.Equal(answer.DeliverySha256, ComputeSHA256(approval.GetDelivery().GetCiphertext())) {
		return nil, ErrMismatch
	}
	if answer.NotAfterUnixSeconds <= now.Unix() || answer.NotAfterUnixSeconds > answer.DecidedUnixSeconds+ApprovalSeconds {
		return nil, ErrExpired
	}
	plaintext, err := openKeyringPayload(receiving, deliveryInfo, approval.Delivery.EncapsulatedKey, answer.RequestSha256, approval.Delivery.Ciphertext)
	if err != nil {
		return nil, err
	}
	contents := &pb.DeliveryContents{}
	if err := proto.Unmarshal(plaintext, contents); err != nil {
		return nil, err
	}
	request, err := ParseLeaseRequestPayload(approval.Request)
	if err != nil {
		return nil, err
	}
	if contents.RequestId != request.RequestId || contents.LoginId != request.LoginId {
		return nil, ErrMismatch
	}
	return contents, nil
}

// VerifySignedMembers accepts a new Members signed by a device the current one
// lists, and newer. With no current Members, it must be signed by a device it lists.
func VerifySignedMembers(signed *pb.Signed, current *pb.Members) (*pb.Members, error) {
	next := &pb.Members{}
	if err := proto.Unmarshal(signed.GetPayload(), next); err != nil {
		return nil, err
	}
	if next.Domain != MembersDomain {
		return nil, ErrWrongDomain
	}
	trusted := next
	if current != nil {
		if next.Revision <= current.Revision {
			return nil, ErrStale
		}
		trusted = current
	}
	if _, err := VerifySignedDocument(signed, trusted, false); err != nil {
		return nil, err
	}
	// A device keeps the kind it joined as: the relay lets a Mac answer its own
	// agents' requests and a Watch post answers, by kind.
	for _, before := range current.GetDevices() {
		for _, after := range next.Devices {
			if after.KeyId == before.KeyId && after.Kind != before.Kind {
				return nil, ErrNotAllowed
			}
		}
	}
	return next, nil
}

// FreshFor is the longest a Freshness may vouch for a computer's lists.
const FreshFor = 7 * 24 * time.Hour

// VerifySignedFreshness accepts a Freshness for machineID signed by the reply key
// of a device in members, and returns until when it vouches: never more than
// a day beyond FreshFor from now.
func VerifySignedFreshness(signed *pb.Signed, members *pb.Members, machineID string, now time.Time) (*pb.Freshness, error) {
	fresh := &pb.Freshness{}
	if err := proto.Unmarshal(signed.GetPayload(), fresh); err != nil {
		return nil, err
	}
	if fresh.Domain != FreshDomain {
		return nil, ErrWrongDomain
	}
	device, err := VerifySignedDocument(signed, members, true)
	if err != nil {
		return nil, err
	}
	if signed.SignerKeyId != device.ReplyKeyId || fresh.MachineId != machineID {
		return nil, ErrNotAllowed
	}
	if limit := now.Add(FreshFor + 24*time.Hour).Unix(); fresh.ValidUntilUnixSeconds > limit {
		fresh.ValidUntilUnixSeconds = limit
	}
	return fresh, nil
}

// VerifySignedCatalogue accepts a newer Catalogue signed by a device in members.
func VerifySignedCatalogue(signed *pb.Signed, members *pb.Members, current *pb.Catalogue) (*pb.Catalogue, error) {
	if _, err := VerifySignedDocument(signed, members, false); err != nil {
		return nil, err
	}
	next := &pb.Catalogue{}
	if err := proto.Unmarshal(signed.Payload, next); err != nil {
		return nil, err
	}
	if next.Domain != CatalogueDomain {
		return nil, ErrWrongDomain
	}
	if current != nil && next.Revision <= current.Revision {
		return nil, ErrStale
	}
	return next, nil
}

// GenerateTOTPCodes gives one code per time step from start until end (RFC 6238).
func GenerateTOTPCodes(secret *pb.LoginSecret, start, end int64) ([]*pb.TimedCode, error) {
	if len(secret.TotpSeed) == 0 {
		return nil, nil
	}
	period, digits := int64(secret.TotpPeriodSeconds), int(secret.TotpDigits)
	if period == 0 {
		period = 30
	}
	if digits == 0 {
		digits = 6
	}
	var makeHash func() hash.Hash
	switch secret.TotpAlgorithm {
	case "", "SHA1":
		makeHash = sha1.New
	case "SHA256":
		makeHash = sha256.New
	case "SHA512":
		makeHash = sha512.New
	default:
		return nil, fmt.Errorf("unknown one-time code algorithm %q", secret.TotpAlgorithm)
	}
	if period < 1 || digits < 6 || digits > 8 {
		return nil, errors.New("invalid one-time code settings")
	}
	modulus := uint32(1)
	for range digits {
		modulus *= 10
	}
	var codes []*pb.TimedCode
	for step := start / period * period; step < end; step += period {
		mac := hmac.New(makeHash, secret.TotpSeed)
		mac.Write(binary.BigEndian.AppendUint64(nil, uint64(step/period)))
		digest := mac.Sum(nil)
		offset := digest[len(digest)-1] & 15
		value := (binary.BigEndian.Uint32(digest[offset:offset+4]) & 0x7fffffff) % modulus
		codes = append(codes, &pb.TimedCode{ValidFromUnixSeconds: step, ValidUntilUnixSeconds: min(step+period, end), Code: fmt.Sprintf("%0*d", digits, value)})
	}
	return codes, nil
}

// ComputeJoinProof proves a joiner holds the secret of an invitation
// (proto/agentkeyring/v2/keyring.proto, JoinRequest.proof).
func ComputeJoinProof(secret []byte, joining *pb.JoinRequest) []byte {
	var message []byte
	switch {
	case joining.GetMachine() != nil:
		m := joining.GetMachine()
		message = lengthPrefixed("agentkeyring.join.v2", "machine", m.Label, m.MachineId, string(m.TlsPublicKey), string(m.ReceivingPublicKey))
	case joining.GetDevice() != nil:
		d := joining.GetDevice()
		parts := []string{"agentkeyring.join.v2", "device", d.Label, d.KeyId, strconv.Itoa(int(d.Kind)), string(d.SigningPublicKey),
			string(d.OpeningPublicKey), string(d.TlsPublicKey), d.ReplyKeyId, string(d.ReplyPublicKey)}
		if len(d.NoticePublicKey) > 0 {
			parts = append(parts, string(d.NoticePublicKey))
		}
		message = lengthPrefixed(parts...)
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write(message)
	return mac.Sum(nil)
}

// DeriveRefusalReplyKey is what only the inviter can send to refuse a machine's join;
// the joiner sends its SHA-256 with the join (JoinRequest.refusal_key_sha256).
func DeriveRefusalReplyKey(secret []byte, machineID string) []byte {
	mac := hmac.New(sha256.New, secret)
	mac.Write(lengthPrefixed("agentkeyring.refusal.v2", "key", machineID))
	return mac.Sum(nil)
}

// ComputeRefusalReplyProof binds the inviter's words to a refusal (JoinRefusal.reply_proof).
func ComputeRefusalReplyProof(secret []byte, machineID, reply string) []byte {
	mac := hmac.New(sha256.New, secret)
	mac.Write(lengthPrefixed("agentkeyring.refusal.v2", "reply", machineID, reply))
	return mac.Sum(nil)
}
