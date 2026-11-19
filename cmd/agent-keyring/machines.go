// Written by AI on 2026.11.19 by model claude opus 5.5.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"text/tabwriter"
)

type tailnetNode struct {
	DNSName, OS string
	Online      bool
}

// machines lists the computers on this tailnet, so an agent can ask which
// one stays on and which run agents. Phones and tablets are left out.
func machines() error {
	binary, err := exec.LookPath("tailscale")
	if err != nil {
		binary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
		if _, e := os.Stat(binary); e != nil {
			return errors.New("Tailscale's command is not on the path and the Tailscale app is not installed. Agent Keyring reaches other computers only over Tailscale.")
		}
	}
	output, err := exec.Command(binary, "status", "--json").Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && len(exit.Stderr) > 0 {
			return fmt.Errorf("tailscale status: %s", strings.TrimSpace(string(exit.Stderr)))
		}
		return fmt.Errorf("tailscale status: %w", err)
	}
	var status struct {
		Self tailnetNode
		Peer map[string]tailnetNode
	}
	if err := json.Unmarshal(output, &status); err != nil || status.Self.DNSName == "" {
		return errors.New("tailscale status gave no computers. Check that Tailscale is connected.")
	}
	var peers []tailnetNode
	for _, node := range status.Peer {
		if node.OS != "iOS" && node.OS != "android" {
			peers = append(peers, node)
		}
	}
	sort.Slice(peers, func(i, j int) bool { return peers[i].DNSName < peers[j].DNSName })
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "COMPUTER\tSYSTEM\tONLINE\tADDRESS")
	row := func(node tailnetNode, note string) {
		address := strings.TrimSuffix(node.DNSName, ".")
		name, _, _ := strings.Cut(address, ".")
		online := map[bool]string{true: "yes", false: "no"}[node.Online]
		fmt.Fprintf(w, "%s%s\t%s\t%s\t%s\n", safe(name), note, safe(node.OS), online, safe(address))
	}
	row(status.Self, " (this computer)")
	for _, node := range peers {
		row(node, "")
	}
	return w.Flush()
}
