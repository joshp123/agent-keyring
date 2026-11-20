// Written by AI on 2026.11.20 by model claude opus 5.5.
package keyring

import (
	"bytes"
	"encoding/hex"
	"testing"
)

// The Mac computes the proof in Swift (SealingTests, setupProofMatchesGo);
// if the two drift, the relay refuses his Mac on its first connection.
func TestSetupProofMatchesTheMac(t *testing.T) {
	want, _ := hex.DecodeString("8572ae376638705097f47924d256bf18bf09e85ab4eaeaa4fe57ad27392da3bb")
	if got := SetupProof(bytes.Repeat([]byte{1}, 32), []byte("spki"), "mac"); !bytes.Equal(got, want) {
		t.Fatalf("setup proof %x", got)
	}
}
