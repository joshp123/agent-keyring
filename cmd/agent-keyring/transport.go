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

// Setup is always directed to the local app, never an enrolled remote authority.
func localSetupAuthority(ctx context.Context) (authority.Client, error) {
	if socket := os.Getenv("AGENT_KEYRING_SOCKET"); socket != "" {
		return authority.Client{Socket: socket}, nil
	}
	if runtime.GOOS != "darwin" {
		return authority.Client{}, errors.New("Run setup commands on the approving Mac.")
	}
	store, err := clientstate.Default()
	if err != nil {
		return authority.Client{}, err
	}
	state, err := store.Load(ctx)
	if err != nil {
		return authority.Client{}, err
	}
	id := bundleID(contentsPath())
	if id == "" && state.LocalAuthority != nil {
		id = state.LocalAuthority.BundleId
	}
	if id == "" {
		id = bundleID("/Applications/AgentKeyring.app/Contents")
	}
	if id == "" {
		return authority.Client{}, errors.New("Cannot find the local app. Run its bundled agent-keyring command or set AGENT_KEYRING_SOCKET.")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return authority.Client{}, err
	}
	return authority.Client{Socket: filepath.Join(home, "Library/Containers", id, "Data/agent.sock")}, nil
}

func chooseAuthority(ctx context.Context) (authority.Client, error) {
	store, err := clientstate.Default()
	if err != nil {
		return authority.Client{}, err
	}
	local := authority.Client{State: store}
	if os.Getenv("AGENT_KEYRING_SOCKET") != "" && os.Getenv("AGENT_KEYRING_RELAY") != "" {
		return authority.Client{}, errors.New("Choose one connection override: AGENT_KEYRING_SOCKET or AGENT_KEYRING_RELAY, not both.")
	}
	if os.Getenv("AGENT_KEYRING_SOCKET") != "" {
		local.Socket = os.Getenv("AGENT_KEYRING_SOCKET")
		return local, nil
	}
	state, err := store.Load(ctx)
	if err != nil {
		return authority.Client{}, err
	}
	if address := os.Getenv("AGENT_KEYRING_RELAY"); address != "" && address != state.RelayAddress {
		return authority.Client{}, errors.New("This relay address is not enrolled. Run enrol for this relay before using it.")
	}

	// Signed enrolment is the selected authority, including for bundled helpers
	// on a Mac that also has a local app. Never fall back when it is unavailable.
	if state.RecipientId != "" || os.Getenv("AGENT_KEYRING_RELAY") != "" {
		client, err := remote.Load(ctx, store)
		if err != nil {
			return authority.Client{}, err
		}
		return client.Authority(), nil
	}
	if state.LocalAuthority == nil && runtime.GOOS == "darwin" {
		contents := "/Applications/AgentKeyring.app/Contents"
		if _, err := os.Stat(filepath.Join(contents, "MacOS/AgentKeyring")); err != nil {
			contents = contentsPath()
		}
		if _, err := os.Stat(filepath.Join(contents, "MacOS/AgentKeyring")); contents != "" && err == nil {
			id := bundleID(contents)
			if id == "" {
				return authority.Client{}, errors.New("Cannot read the local Agent Keyring app's bundle identity. Reinstall the app or enrol this machine with its relay.")
			}
			err = store.Update(ctx, func(current *clientstate.State) error {
				if current.RecipientId == "" && current.LocalAuthority == nil {
					current.LocalAuthority = &clientstate.LocalAuthority{ApplicationContents: contents, BundleId: id}
				}
				return nil
			})
			if err != nil {
				return authority.Client{}, err
			}
			// Enrolment may have finished while the local choice was being saved.
			return chooseAuthority(ctx)
		}
	}
	if selected := state.LocalAuthority; selected != nil {
		home, err := os.UserHomeDir()
		if err != nil {
			return authority.Client{}, err
		}
		local.Socket = filepath.Join(home, "Library/Containers", selected.BundleId, "Data/agent.sock")
		local.Start = func(ctx context.Context) error { return startApp(ctx, selected.ApplicationContents) }
		return local, nil
	}
	return authority.Client{}, errors.New("No authority is selected. Install the Mac app here, or run 'agent-keyring enrol --name NAME --invite LINK' with a link from 'agent-keyring invite' on the Mac.")
}
