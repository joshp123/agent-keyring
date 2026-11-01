// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"time"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
)

// This is the existing Python dummy site's fixture, not a keyring protocol.
type browserFixture struct {
	Origin, Username, Password string
	Seed                       string `json:"totp_secret"`
}

func loadBrowserFixture(path string) *browserFixture {
	raw, err := os.ReadFile(path)
	must(err)
	fixture := new(browserFixture)
	must(json.Unmarshal(raw, fixture))
	origin, err := url.Parse(fixture.Origin)
	must(err)
	require(net.ParseIP(origin.Hostname()).IsLoopback() && origin.Scheme == "http", "browser fixture must name a loopback dummy site")
	return fixture
}

func (f *browserFixture) populate(values *pb.BundleContents) {
	values.Sites, values.Username, values.Password = []string{f.Origin}, f.Username, f.Password
	seed, err := base64.StdEncoding.DecodeString(f.Seed)
	must(err)
	defer clear(seed)
	for start := time.Now().Unix() / 30 * 30; start < values.NotAfterUnixSeconds; start += 30 {
		var counter [8]byte
		binary.BigEndian.PutUint64(counter[:], uint64(start/30))
		hash := hmac.New(sha1.New, seed)
		hash.Write(counter[:])
		digest := hash.Sum(nil)
		offset := digest[len(digest)-1] & 15
		code := fmt.Sprintf("%06d", (binary.BigEndian.Uint32(digest[offset:offset+4])&0x7fffffff)%1000000)
		values.OneTimeCodes = append(values.OneTimeCodes, &pb.TimedCode{ValidFromUnixSeconds: start, ValidUntilUnixSeconds: min(start+30, values.NotAfterUnixSeconds), Code: code})
	}
}
