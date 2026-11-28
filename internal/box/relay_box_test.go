// Written by AI on 2026.11.23 by model claude opus 5.5; part nonces, grants
// and mailboxes on 2026.11.24.
//
// The golden vectors the Swift side checks too (AgentKeyringSealingTests,
// BoxVectorTests): a code as a person types it, its keys and boxes, and a
// message sealed into one box and into two.
package box

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

type relayBoxTestVectors struct {
	Codes []struct {
		Secret string   `json:"secret"`
		Code   string   `json:"code"`
		Typed  []string `json:"typed"`
	} `json:"codes"`
	NotCodes []string `json:"not_codes"`
	Link     struct {
		Relay string `json:"relay"`
		Text  string `json:"text"`
	} `json:"link"`
	Join struct {
		Secret      string `json:"secret"`
		RequestBox  string `json:"request_box"`
		RequestKey  string `json:"request_key"`
		ResponseBox string `json:"response_box"`
		ResponseKey string `json:"response_key"`
		Proof       string `json:"proof"`
	} `json:"join"`
	Seal struct {
		Box       string `json:"box"`
		Key       string `json:"key"`
		Message   string `json:"message"`
		Nonce     string `json:"nonce"`
		Plaintext string `json:"plaintext"`
		Sealed    string `json:"sealed"`
		PartNonce string `json:"part_nonce"`
		Part1Box  string `json:"part_1_box"`
	} `json:"seal"`
	Grant struct {
		Box       string `json:"box"`
		ReadAuth  string `json:"read_auth"`
		WriteAuth string `json:"write_auth"`
	} `json:"grant"`
	Mailbox struct {
		Seed   string `json:"seed"`
		Device string `json:"device"`
		Slot   string `json:"slot"`
		Key    string `json:"key"`
	} `json:"mailbox"`
	Parts struct {
		Length        int      `json:"length"`
		Nonces        []string `json:"nonces"`
		SealedLengths []int    `json:"sealed_lengths"`
		SealedSHA256  []string `json:"sealed_sha256"`
	} `json:"parts"`
}

func decodeBoxTestHex(t *testing.T, text string) []byte {
	t.Helper()
	raw, err := hex.DecodeString(text)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestBoxVectors(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/box/vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v relayBoxTestVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}

	t.Run("codes", func(t *testing.T) { checkCodeVectors(t, &v) })
	t.Run("derived keys", func(t *testing.T) { checkJoinVectors(t, &v) })
	t.Run("sealed messages", func(t *testing.T) { checkSealVectors(t, &v) })
	t.Run("multipart messages", func(t *testing.T) { checkPartsVectors(t, &v) })
}

func checkCodeVectors(t *testing.T, v *relayBoxTestVectors) {
	t.Helper()
	for _, c := range v.Codes {
		if got := FormatComputerJoinCode(decodeBoxTestHex(t, c.Secret)); got != c.Code {
			t.Errorf("Code(%s) = %s, want %s", c.Secret, got, c.Code)
		}
		for _, typed := range append(c.Typed, c.Code) {
			if secret, err := ParseComputerJoinCode(typed); err != nil || hex.EncodeToString(secret) != c.Secret {
				t.Errorf("ParseCode(%q) = %x, %v; want %s", typed, secret, err, c.Secret)
			}
		}
	}
	for _, typed := range v.NotCodes {
		if _, err := ParseComputerJoinCode(typed); err == nil {
			t.Errorf("ParseCode(%q) took a code that is not one", typed)
		}
	}
	if got := FormatComputerJoinLink(decodeBoxTestHex(t, v.Join.Secret), v.Link.Relay); got != v.Link.Text {
		t.Errorf("Link = %s, want %s", got, v.Link.Text)
	}
	if secret, relay, err := ParseComputerJoinCodeOrLink(v.Link.Text); err != nil || hex.EncodeToString(secret) != v.Join.Secret || relay != v.Link.Relay {
		t.Errorf("ParseCodeOrLink(link) = %x %q %v", secret, relay, err)
	}

}

func checkJoinVectors(t *testing.T, v *relayBoxTestVectors) {
	t.Helper()
	keys := DeriveComputerJoinCodeKeys(decodeBoxTestHex(t, v.Join.Secret))
	for name, pair := range map[string][2]string{
		"request box": {keys.RequestBox, v.Join.RequestBox}, "request key": {hex.EncodeToString(keys.RequestKey), v.Join.RequestKey},
		"response box": {keys.ResponseBox, v.Join.ResponseBox}, "response key": {hex.EncodeToString(keys.ResponseKey), v.Join.ResponseKey},
		"proof": {hex.EncodeToString(keys.Proof), v.Join.Proof},
	} {
		if pair[0] != pair[1] {
			t.Errorf("%s = %s, want %s", name, pair[0], pair[1])
		}
	}

}

func checkSealVectors(t *testing.T, v *relayBoxTestVectors) {
	t.Helper()
	one := SplitIntoBoxChunks(v.Seal.Box, decodeBoxTestHex(t, v.Seal.PartNonce), []byte(v.Seal.Message))
	if len(one) != 1 || one[0].ID != v.Seal.Box || hex.EncodeToString(one[0].Plaintext) != v.Seal.Plaintext {
		t.Fatalf("Parts(message) = %+v", one)
	}
	plaintext := [][]byte{one[0].Plaintext}
	sealed, err := SealBoxChunk(decodeBoxTestHex(t, v.Seal.Key), v.Seal.Box, decodeBoxTestHex(t, v.Seal.Nonce), plaintext[0])
	if err != nil || hex.EncodeToString(sealed) != v.Seal.Sealed {
		t.Errorf("SealPart = %x, %v; want %s", sealed, err, v.Seal.Sealed)
	}
	if opened, err := OpenBoxChunk(decodeBoxTestHex(t, v.Seal.Key), v.Seal.Box, decodeBoxTestHex(t, v.Seal.Sealed)); err != nil || !bytes.Equal(opened, plaintext[0]) {
		t.Errorf("OpenPart = %x, %v", opened, err)
	}
	if _, err := OpenBoxChunk(decodeBoxTestHex(t, v.Seal.Key), v.Seal.Part1Box, decodeBoxTestHex(t, v.Seal.Sealed)); err == nil {
		t.Error("a box opened under another box's id: the relay could swap boxes")
	}
	if got := DeriveChunkBoxID(decodeBoxTestHex(t, v.Seal.PartNonce), 1); got != v.Seal.Part1Box {
		t.Errorf("PartID(nonce, 1) = %s, want %s", got, v.Seal.Part1Box)
	}
	if got := DeriveLeaseGrantBox(v.Seal.Box, decodeBoxTestHex(t, v.Seal.Key)); got != (LeaseGrantBox{v.Grant.Box, v.Grant.ReadAuth, v.Grant.WriteAuth}) {
		t.Errorf("GrantFor = %+v, want %+v", got, v.Grant)
	}
	seed := decodeBoxTestHex(t, v.Mailbox.Seed)
	if slot, key := DeriveUpdateMailboxSlot(seed, v.Mailbox.Device), hex.EncodeToString(DeriveUpdateMailboxKey(seed)); slot != v.Mailbox.Slot || key != v.Mailbox.Key {
		t.Errorf("mailbox slot %s key %s, want %s %s", slot, key, v.Mailbox.Slot, v.Mailbox.Key)
	}

}

func checkPartsVectors(t *testing.T, v *relayBoxTestVectors) {
	t.Helper()
	message := make([]byte, v.Parts.Length)
	for i := range message {
		message[i] = byte(i % 251)
	}
	parts := SplitIntoBoxChunks(v.Join.ResponseBox, decodeBoxTestHex(t, v.Seal.PartNonce), message)
	if len(parts) != len(v.Parts.Nonces) {
		t.Fatalf("%d parts, want %d", len(parts), len(v.Parts.Nonces))
	}
	for i, part := range parts {
		sealed, err := SealBoxChunk(decodeBoxTestHex(t, v.Join.ResponseKey), part.ID, decodeBoxTestHex(t, v.Parts.Nonces[i]), part.Plaintext)
		digest := sha256.Sum256(sealed)
		if err != nil || len(sealed) != v.Parts.SealedLengths[i] || hex.EncodeToString(digest[:]) != v.Parts.SealedSHA256[i] {
			t.Errorf("part %d: %d bytes, SHA-256 %x, %v", i, len(sealed), digest, err)
		}
	}
}
