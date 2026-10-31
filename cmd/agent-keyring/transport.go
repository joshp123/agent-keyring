// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"

	"github.com/joshp123/agent-keyring/internal/authority"
	"github.com/joshp123/agent-keyring/internal/clientstate"
	"github.com/joshp123/agent-keyring/internal/remote"
)

func chooseAuthority(ctx context.Context) (authority.Client, error) {
	store, err := clientstate.Default()
	if err != nil {
		return authority.Client{}, err
	}
	local := authority.Client{Socket: socketPath(), State: store}
	if os.Getenv("AGENT_KEYRING_SOCKET") != "" {
		return local, nil
	}
	if info, err := os.Stat(local.Socket); os.Getenv("AGENT_KEYRING_RELAY") == "" && err == nil && info.Mode()&os.ModeSocket != 0 {
		return local, nil
	}
	// A Mac with the app keeps its local authority, starting it when needed.
	if runtime.GOOS == "darwin" && os.Getenv("AGENT_KEYRING_RELAY") == "" {
		contents := contentsPath()
		if contents == "" {
			contents = "/Applications/AgentKeyring.app/Contents"
		}
		if _, err := os.Stat(filepath.Join(contents, "MacOS/AgentKeyring")); err == nil {
			local.Start = startApp
			return local, nil
		}
	}
	state, err := store.Load(ctx)
	if err != nil {
		return authority.Client{}, err
	}
	if address := os.Getenv("AGENT_KEYRING_RELAY"); address != "" && address != state.RelayAddress {
		return authority.Client{}, errors.New("This relay address is not enrolled. Run enrol for this relay before using it.")
	}

	client, err := remote.Load(ctx, store)
	if err != nil {
		return authority.Client{}, err
	}
	return client.Authority(), nil
}
