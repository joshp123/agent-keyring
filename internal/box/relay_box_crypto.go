// Written by AI on 2026.11.23 by model claude opus 5.5; GET, grants and
// update mailboxes on 2026.11.24.
//
// Package box is the relay's boxes, which carry everything between a
// computer and Josh's devices (proto/agentkeyring/v2/keyring.proto, "Boxes"): the join code
// and its keys, sealing a message into one or more boxes, the grant a Stop
// marks, the update mailbox, and the client for /v1/box.
package box

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

// DefaultURL is the relay boxes go to unless a code or the environment names another.
const DefaultURL = "https://push.opentrawl.sh"

// PartSize is the most of a message one box holds, under the relay's 256 KiB.
const PartSize = 196608

// MaxParts is the most boxes one message may take.
const MaxParts = 64

// How long a box lasts at the relay (x-akr-ttl).
const (
	TTLEnrol  = "enrol"  // 600 s: joins and answers.
	TTLGrant  = "grant"  // 2700 s: an approval's grant, and its Stop.
	TTLUpdate = "update" // 604800 s: an update mailbox's slot.
)

// What a PUT does (x-akr-mode).
const (
	ModeCreate  = "create"
	ModeReplace = "replace"
	ModeStop    = "stop"
)

var validID = regexp.MustCompile(`^[0-9a-f]{32,64}$`)

// IsValidBoxID is true for an id the relay takes: 32 to 64 lowercase hex characters.
func IsValidBoxID(id string) bool { return validID.MatchString(id) }

// GenerateBoxID is a fresh random box id and key, for one message.
func GenerateBoxID() (string, []byte) {
	id, key := make([]byte, 32), make([]byte, 32)
	rand.Read(id)
	rand.Read(key)
	return hex.EncodeToString(id), key
}

// GenerateBoxAuthToken is a fresh read or write token: 32 random bytes, base64url.
func GenerateBoxAuthToken() string {
	raw := make([]byte, 32)
	rand.Read(raw)
	return base64.RawURLEncoding.EncodeToString(raw)
}

func deriveBoxKey(secret []byte, info string) []byte {
	out, err := hkdf.Key(sha256.New, secret, nil, info, 32)
	if err != nil {
		panic(err)
	}
	return out
}

func hashBoxIdentifier(text string) string {
	digest := sha256.Sum256([]byte(text))
	return hex.EncodeToString(digest[:])
}

// ---- Grants --------------------------------------------------------------------

// LeaseGrantBox is where an approval answered in a box is marked live or stopped.
type LeaseGrantBox struct {
	ID        string
	ReadAuth  string
	WriteAuth string
}

// DeriveLeaseGrantBox is the grant of the request answered in answerBox with answerKey.
func DeriveLeaseGrantBox(answerBox string, answerKey []byte) LeaseGrantBox {
	return LeaseGrantBox{ID: hashBoxIdentifier("agentkeyring.grant.v1" + answerBox),
		ReadAuth:  base64.RawURLEncoding.EncodeToString(deriveBoxKey(answerKey, "agentkeyring.grant.v1 read auth")),
		WriteAuth: base64.RawURLEncoding.EncodeToString(deriveBoxKey(answerKey, "agentkeyring.grant.v1 write auth"))}
}

// ---- Update mailboxes -------------------------------------------------------------

// DeriveUpdateMailboxSlot is the box a device writes a computer's updates in.
func DeriveUpdateMailboxSlot(seed []byte, deviceKeyID string) string {
	return hex.EncodeToString(deriveBoxKey(seed, "agentkeyring.mailbox.v1 slot "+deviceKeyID))
}

// DeriveUpdateMailboxKey seals every slot of a mailbox.
func DeriveUpdateMailboxKey(seed []byte) []byte {
	return deriveBoxKey(seed, "agentkeyring.mailbox.v1 key")
}

// ---- URLs ------------------------------------------------------------------------

// ValidateRelayBoxURL accepts a relay's URL: https with a host and nothing after the
// path, or plain http to loopback when loopbackHTTP (tests only). It returns
// the URL without a trailing slash.
func ValidateRelayBoxURL(raw string, loopbackHTTP bool) (string, error) {
	parsed, err := url.Parse(raw)
	bad := fmt.Errorf("%q is not a relay URL: it must be https://HOST with no user, password, query or fragment", raw)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.ForceQuery || parsed.Fragment != "" || parsed.Opaque != "" {
		return "", bad
	}
	loopback := parsed.Hostname() == "127.0.0.1" || parsed.Hostname() == "localhost"
	if parsed.Scheme != "https" && !(parsed.Scheme == "http" && loopback && loopbackHTTP) {
		return "", bad
	}
	return strings.TrimRight(raw, "/"), nil
}

// ---- Sealing -----------------------------------------------------------------------

// DeriveChunkBoxID is the box that holds part i > 0 of a message whose part nonce is nonce.
func DeriveChunkBoxID(nonce []byte, i uint32) string {
	digest := sha256.Sum256(binary.BigEndian.AppendUint32([]byte("agentkeyring.box.part.v1"+hex.EncodeToString(nonce)), i))
	return hex.EncodeToString(digest[:])
}

func newBoxCipher(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, errors.New("a box key is 32 bytes")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// SealBoxChunk seals one part's plaintext for box id. nonce is 12 bytes; nil
// takes fresh random ones (only a test fixes it).
func SealBoxChunk(key []byte, id string, nonce, plaintext []byte) ([]byte, error) {
	gcm, err := newBoxCipher(key)
	if err != nil {
		return nil, err
	}
	if nonce == nil {
		nonce = make([]byte, gcm.NonceSize())
		rand.Read(nonce)
	} else if len(nonce) != gcm.NonceSize() {
		return nil, errors.New("a box nonce is 12 bytes")
	}
	return gcm.Seal(append([]byte(nil), nonce...), nonce, plaintext, []byte("agentkeyring.box.v1"+id)), nil
}

// ErrUnreadable is a box that is not a message sealed for it with this key.
var ErrUnreadable = errors.New("the box does not open with this key: it was not sealed for this request")

// OpenBoxChunk opens what SealBoxChunk sealed for box id.
func OpenBoxChunk(key []byte, id string, sealed []byte) ([]byte, error) {
	gcm, err := newBoxCipher(key)
	if err != nil {
		return nil, err
	}
	if len(sealed) < gcm.NonceSize()+gcm.Overhead() {
		return nil, ErrUnreadable
	}
	plaintext, err := gcm.Open(nil, sealed[:gcm.NonceSize()], sealed[gcm.NonceSize():], []byte("agentkeyring.box.v1"+id))
	if err != nil {
		return nil, ErrUnreadable
	}
	return plaintext, nil
}

// RelayBoxChunk is one part's box and plaintext.
type RelayBoxChunk struct {
	ID        string
	Plaintext []byte
}

// SplitIntoBoxChunks cuts a message for box id into its parts, part 0 first, with part
// nonce nonce (16 bytes).
func SplitIntoBoxChunks(id string, nonce, message []byte) []RelayBoxChunk {
	n := max(1, (len(message)+PartSize-1)/PartSize)
	parts := make([]RelayBoxChunk, n)
	for i := range parts {
		chunk := message[i*PartSize : min(len(message), (i+1)*PartSize)]
		plaintext := binary.BigEndian.AppendUint32(nil, uint32(n))
		partID := id
		if i == 0 {
			plaintext = append(plaintext, nonce...)
		} else {
			partID = DeriveChunkBoxID(nonce, uint32(i))
		}
		parts[i] = RelayBoxChunk{partID, append(plaintext, chunk...)}
	}
	return parts
}

// ---- Joining with a code -------------------------------------------------------

// Crockford's base32 alphabet: no I, L, O or U.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// FormatComputerJoinCode shows a 16-byte secret as 26 characters in groups of four.
func FormatComputerJoinCode(secret []byte) string {
	var bits uint64
	var have uint
	var out []byte
	for _, b := range append(append([]byte(nil), secret...), 0) { // The zero byte pads the last character.
		bits, have = bits<<8|uint64(b), have+8
		for have >= 5 && len(out) < 26 {
			have -= 5
			out = append(out, alphabet[(bits>>have)&31])
		}
	}
	var grouped strings.Builder
	for i, c := range out {
		if i > 0 && i%4 == 0 {
			grouped.WriteByte('-')
		}
		grouped.WriteByte(c)
	}
	return grouped.String()
}

var errCode = errors.New("That is not a join code. A code is 26 letters and digits, like ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-23, from Add Another Computer on the Mac or iPhone.")

// ParseComputerJoinCode reads a code as a person typed it: any case, with or without
// hyphens or spaces, I and L for 1, O for 0.
func ParseComputerJoinCode(text string) ([]byte, error) {
	cleaned := strings.NewReplacer("-", "", " ", "", "I", "1", "L", "1", "O", "0").Replace(strings.ToUpper(strings.TrimSpace(text)))
	if len(cleaned) != 26 {
		return nil, errCode
	}
	var bits uint64
	var have uint
	var secret []byte
	for i := 0; i < len(cleaned); i++ {
		value := strings.IndexByte(alphabet, cleaned[i])
		if value < 0 {
			return nil, errCode
		}
		bits, have = bits<<5|uint64(value), have+5
		if have >= 8 && len(secret) < 16 {
			have -= 8
			secret = append(secret, byte(bits>>have))
		}
	}
	if bits&3 != 0 { // The two padding bits.
		return nil, errCode
	}
	return secret, nil
}

// FormatComputerJoinLink is a code as a link, naming the relay if it is not the default.
func FormatComputerJoinLink(secret []byte, relay string) string {
	link := "agentkeyring://join?code=" + strings.ReplaceAll(FormatComputerJoinCode(secret), "-", "")
	if relay != "" && relay != DefaultURL {
		link += "&relay=" + url.QueryEscape(relay)
	}
	return link
}

// ParseComputerJoinCodeOrLink reads a bare code or a link, and the relay it names ("" for none).
func ParseComputerJoinCodeOrLink(text string) (secret []byte, relay string, err error) {
	text = strings.TrimSpace(text)
	if rest, ok := strings.CutPrefix(text, "agentkeyring://join?"); ok {
		query, err := url.ParseQuery(rest)
		if err != nil || query.Get("code") == "" {
			return nil, "", errCode
		}
		secret, err := ParseComputerJoinCode(query.Get("code"))
		return secret, query.Get("relay"), err
	}
	secret, err = ParseComputerJoinCode(text)
	return secret, "", err
}

// ComputerJoinCodeKeys is everything a code gives both sides of a join.
type ComputerJoinCodeKeys struct {
	RequestBox  string
	RequestKey  []byte
	ResponseBox string
	ResponseKey []byte
	Proof       []byte // The secret for JoinRequest.proof and JoinRefusal.
}

func DeriveComputerJoinCodeKeys(secret []byte) ComputerJoinCodeKeys {
	part := func(info string) []byte { return deriveBoxKey(secret, "agentkeyring.join.v1 "+info) }
	return ComputerJoinCodeKeys{RequestBox: hex.EncodeToString(part("request box")), RequestKey: part("request key"),
		ResponseBox: hex.EncodeToString(part("response box")), ResponseKey: part("response key"), Proof: part("proof")}
}
