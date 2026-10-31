// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package relay

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os/exec"
)

type Node struct {
	ID, Name, Address string
	Tags              []string
}
type NodeLookup func(context.Context, string) (Node, error)

// TailscaleLookup asks the local daemon for the authenticated source node. The
// JSON is Tailscale's CLI boundary, never a credential or keyring contract.
func TailscaleLookup(binary string) NodeLookup {
	return func(ctx context.Context, address string) (Node, error) {
		output, err := exec.CommandContext(ctx, binary, "whois", "--json", address).Output()
		if err != nil {
			return Node{}, errors.New("Tailscale could not identify the peer")
		}
		var result struct {
			Node struct {
				StableID, Name string
				Tags           []string
			}
		}
		if err = json.Unmarshal(output, &result); err != nil || result.Node.StableID == "" {
			return Node{}, errors.New("Tailscale returned no stable node identity")
		}
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return Node{}, errors.New("Tailscale peer has no network address")
		}
		return Node{ID: result.Node.StableID, Name: result.Node.Name, Address: host, Tags: result.Node.Tags}, nil
	}
}
