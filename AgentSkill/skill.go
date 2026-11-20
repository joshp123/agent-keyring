// Package agentskill is the instructions agents follow, built into the
// command so `agent-keyring skill` works however the command was installed.
package agentskill

import _ "embed"

//go:embed agent-keyring/SKILL.md
var Text string
