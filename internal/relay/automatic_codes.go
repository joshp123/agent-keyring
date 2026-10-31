// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package relay

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/binary"
	"fmt"
	"hash"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
)

func codeParameters(login *pb.AutomaticLoginContents) (int64, int, func() hash.Hash, error) {
	period, digits, algorithm := int64(login.TotpPeriodSeconds), int(login.TotpDigits), login.TotpAlgorithm
	if period == 0 {
		period = 30
	}
	if digits == 0 {
		digits = 6
	}
	if algorithm == "" {
		algorithm = "SHA1"
	}
	if period < 1 || digits < 6 || digits > 8 {
		return 0, 0, nil, invalid("Invalid one-time code parameters in login copy.")
	}
	var makeHash func() hash.Hash
	switch algorithm {
	case "SHA1":
		makeHash = sha1.New
	case "SHA256":
		makeHash = sha256.New
	case "SHA512":
		makeHash = sha512.New
	default:
		return 0, 0, nil, invalid("Unknown one-time code algorithm in login copy.")
	}
	return period, digits, makeHash, nil
}
func validateCodeParameters(login *pb.AutomaticLoginContents) error {
	if len(login.TotpSeed) == 0 {
		return nil
	}
	_, _, _, err := codeParameters(login)
	return err
}
func automaticCodes(login *pb.AutomaticLoginContents, now, deadline int64) ([]*pb.TimedCode, error) {
	if len(login.TotpSeed) == 0 {
		return nil, nil
	}
	period, digits, makeHash, err := codeParameters(login)
	if err != nil {
		return nil, err
	}
	modulus := uint32(1)
	for range digits {
		modulus *= 10
	}
	var codes []*pb.TimedCode
	for start := now / period * period; start < deadline; start += period {
		mac := hmac.New(makeHash, login.TotpSeed)
		mac.Write(binary.BigEndian.AppendUint64(nil, uint64(start/period)))
		digest := mac.Sum(nil)
		offset := digest[len(digest)-1] & 15
		value := (binary.BigEndian.Uint32(digest[offset:offset+4]) & 0x7fffffff) % modulus
		codes = append(codes, &pb.TimedCode{ValidFromUnixSeconds: start, ValidUntilUnixSeconds: min(start+period, deadline), Code: fmt.Sprintf("%0*d", digits, value)})
	}
	return codes, nil
}
