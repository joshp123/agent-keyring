// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/joshp123/agent-keyring/internal/clientstate"
	"google.golang.org/protobuf/proto"
)

func (p *proof) cliCommand(arguments ...string) *exec.Cmd {
	command := exec.Command(p.cli, arguments...)
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "AGENT_KEYRING_SOCKET=") && !strings.HasPrefix(entry, "AGENT_KEYRING_RELAY=") && !strings.HasPrefix(entry, "AGENT_KEYRING_STATE_DIR=") {
			command.Env = append(command.Env, entry)
		}
	}
	command.Env = append(command.Env, "AGENT_KEYRING_RELAY=127.0.0.1:17445", "AGENT_KEYRING_STATE_DIR="+filepath.Join(p.root, "cli"))
	return command
}
func (p *proof) realCLIProgram() {
	if p.cli == "" {
		return
	}
	command := p.cliCommand("enrol", "--name", "Actual CLI dummy receiver", "--relay", "127.0.0.1:17445")
	var output, diagnostic bytes.Buffer
	command.Stdout = &output
	command.Stderr = &diagnostic
	old := p.owner.enrol[1]
	must(command.Start())
	enrol := p.owner.wait(func(e []string) bool { return e[0] == "ENROL" && e[1] != old })
	p.owner.action("enrol", enrol[1], enrol[2], "true")
	must(command.Wait())
	require(output.Len() == 0 && strings.Contains(diagnostic.String(), enrol[2]), "actual CLI enrolment fingerprint differs")
	data, e := os.ReadFile(filepath.Join(p.root, "cli/state.pb"))
	must(e)
	var state clientstate.State
	must(proto.Unmarshal(data, &state))
	p.cliRecipient = state.RecipientId
	marker := filepath.Join(p.root, "program-count")
	code := "import pathlib,sys;value=sys.stdin.read();assert value=='example-password';p=pathlib.Path(sys.argv[1]);p.write_text(p.read_text()+'1' if p.exists() else '1');print(value)"
	command = p.cliCommand("lease", loginID, "--task", "real-cli-program", "--reason", "Dummy program sign-in", "--for", "program", "--", "/usr/bin/python3", "-c", code, marker)
	output.Reset()
	diagnostic.Reset()
	command.Stdout = &output
	command.Stderr = &diagnostic
	p.owner.status()
	before := p.owner.authorizations
	must(command.Start())
	pending := p.owner.wait(func(e []string) bool { return e[0] == "REQUEST" && e[3] == "1" && e[4] == "false" })
	p.owner.action("approve", pending[1])
	must(command.Wait())
	lease := strings.TrimSpace(output.String())
	require(lease != "", "actual CLI lease returned no reference")
	for i := 0; i < 2; i++ {
		command = p.cliCommand("exec", lease, "--field", "password", "--operation", "login")
		output.Reset()
		diagnostic.Reset()
		command.Stdout = &output
		command.Stderr = &diagnostic
		must(command.Run())
		require(output.Len() == 0 && !strings.Contains(diagnostic.String(), "example-password"), "program output exposed dummy password")
	}
	data, e = os.ReadFile(marker)
	must(e)
	require(string(data) == "1", "actual CLI retry ran twice")
	must(p.cliCommand("release", lease).Run())
	p.owner.status()
	if report := p.owner.leases[lease]; len(report) == 0 || report[2] != "5" {
		p.owner.wait(func(e []string) bool { return e[0] == "LEASE" && e[1] == lease && e[2] == "5" })
	}
	require(p.owner.authorizations == before+1, "actual CLI program needed another approval")
	println("PASS actual CLI enrolment and Ask program sign-in: one approval, echo suppressed, retry executed once, release")
}
func (p *proof) realCLIBrowser() {
	if p.cli == "" {
		return
	}
	command := p.cliCommand("lease", loginID, "--task", "real-cli-read", "--reason", "Dummy private process", "--for", "agent-process")
	leaseBytes, e := command.Output()
	must(e)
	lease := strings.TrimSpace(string(leaseBytes))
	value, e := p.cliCommand("read", lease, "--field", "password").Output()
	must(e)
	require(string(value) == "example-password", "actual CLI did not open Swift-sealed password")
	clear(value)
	code, e := p.cliCommand("read", lease, "--field", "one-time-code").Output()
	must(e)
	require(len(code) == 6, "actual CLI did not open current Swift TOTP window")
	clear(code)
	must(p.cliCommand("release", lease).Run())
	println("PASS actual CLI private password and current code from Swift bundle under Automatic grant")
	if p.browserScript != "" {
		command = p.cliCommand()
		command.Path = "/usr/bin/python3"
		command.Args = []string{"/usr/bin/python3", p.browserScript, "--cli", p.cli}
		command.Stdout = os.Stdout
		command.Stderr = os.Stderr
		must(command.Run())
	}
}
