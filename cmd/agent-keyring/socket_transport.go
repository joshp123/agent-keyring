// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/authority"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
	"github.com/opentrawl/agent-keyring/internal/remote"
)

// Setup is always directed to the local app, never an enrolled remote authority.
func localSetupAuthority(ctx context.Context) (authority.KeyringAuthorityClient, error) {
	if socket := os.Getenv("AGENT_KEYRING_SOCKET"); socket != "" {
		return authority.KeyringAuthorityClient{Socket: socket}, nil
	}
	if runtime.GOOS != "darwin" {
		return authority.KeyringAuthorityClient{}, errors.New("Run setup commands on the approving Mac.")
	}
	store, err := clientstate.DefaultClientStateStore()
	if err != nil {
		return authority.KeyringAuthorityClient{}, err
	}
	state, err := store.LoadClientState(ctx)
	if err != nil {
		return authority.KeyringAuthorityClient{}, err
	}
	id := bundleID(ctx, contentsPath())
	if id == "" && state.LocalAuthority != nil {
		id = state.LocalAuthority.BundleId
	}
	if id == "" {
		id = bundleID(ctx, "/Applications/AgentKeyring.app/Contents")
	}
	if id == "" {
		return authority.KeyringAuthorityClient{}, errors.New("Cannot find the local app. Run its bundled agent-keyring command or set AGENT_KEYRING_SOCKET.")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return authority.KeyringAuthorityClient{}, err
	}
	return authority.KeyringAuthorityClient{Socket: filepath.Join(home, "Library/Containers", id, "Data/agent.sock")}, nil
}

func chooseAuthority(ctx context.Context) (authority.KeyringAuthorityClient, error) {
	store, err := clientstate.DefaultClientStateStore()
	if err != nil {
		return authority.KeyringAuthorityClient{}, err
	}
	local := authority.KeyringAuthorityClient{State: store}
	if socket := os.Getenv("AGENT_KEYRING_SOCKET"); socket != "" {
		local.Socket = socket
		return local, nil
	}
	state, err := store.LoadClientState(ctx)
	if err != nil {
		return authority.KeyringAuthorityClient{}, err
	}
	// Signed enrolment is the selected authority, including for bundled helpers
	// on a Mac that also has a local app. Never fall back when it is unavailable.
	if state.RecipientId != "" {
		client, err := remote.LoadRemoteKeyringClient(ctx, store)
		if err != nil {
			return authority.KeyringAuthorityClient{}, err
		}
		return client.BuildRemoteAuthority(), nil
	}
	return chooseLocalAuthority(ctx, local, state.LocalAuthority)
}

func chooseLocalAuthority(ctx context.Context, local authority.KeyringAuthorityClient, selected *clientstate.LocalAuthority) (authority.KeyringAuthorityClient, error) {
	if runtime.GOOS == "darwin" {
		// A command bundled in an app serves that app, even beside another copy.
		if bundled := contentsPath(); hasLocalApp(bundled) {
			if id := bundleID(ctx, bundled); id != "" {
				return appAuthority(local, bundled, id)
			}
		}
		if selected == nil {
			saved, err := selectLocalApp(ctx, local.State)
			if err != nil {
				return authority.KeyringAuthorityClient{}, err
			}
			if saved {
				// Enrolment may have finished while the local choice was being saved.
				return chooseAuthority(ctx)
			}
		}
	}
	if selected != nil {
		return appAuthority(local, selected.ApplicationContents, selected.BundleId)
	}
	return authority.KeyringAuthorityClient{}, errors.New("No authority is selected. Install the Mac app here, or run 'agent-keyring enrol --name NAME --code CODE' with a code from Add Another Computer on the Mac or iPhone.")
}

func hasLocalApp(contents string) bool {
	if contents == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(contents, "MacOS/AgentKeyring"))
	return err == nil
}

func appAuthority(local authority.KeyringAuthorityClient, contents, id string) (authority.KeyringAuthorityClient, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return authority.KeyringAuthorityClient{}, err
	}
	local.Socket = filepath.Join(home, "Library/Containers", id, "Data/agent.sock")
	local.Start = func(ctx context.Context) error { return startApp(ctx, contents) }
	return local, nil
}

func selectLocalApp(ctx context.Context, store clientstate.ClientStateStore) (bool, error) {
	contents := "/Applications/AgentKeyring.app/Contents"
	if !hasLocalApp(contents) {
		contents = contentsPath()
	}
	if !hasLocalApp(contents) {
		return false, nil
	}
	id := bundleID(ctx, contents)
	if id == "" {
		return false, errors.New("Cannot read the local Agent Keyring app's bundle identity. Reinstall the app.")
	}
	return true, store.UpdateClientState(ctx, func(current *clientstate.State) error {
		if current.RecipientId == "" && current.LocalAuthority == nil {
			current.LocalAuthority = &clientstate.LocalAuthority{ApplicationContents: contents, BundleId: id}
		}
		return nil
	})
}

// gatherLogs asks the Mac app on this Mac; on another computer, it reads its own lines.
func gatherLogs(ctx context.Context, since int64, requestID string) ([]string, error) {
	if local, err := localSetupAuthority(ctx); err == nil {
		result, err := local.CallKeyringAuthority(ctx, &pb.AgentRequest{Request: &pb.AgentRequest_Setup{Setup: &pb.SetupRequest{
			Action: pb.SetupRequest_LOGS, SinceUnixSeconds: since, RequestId: requestID}}})
		if err == nil {
			return result.GetSetup().GetLogLines(), nil
		}
		if _, statErr := os.Stat(local.Socket); statErr == nil {
			return nil, err
		}
	}
	store, err := clientstate.DefaultClientStateStore()
	if err != nil {
		return nil, err
	}
	client, err := remote.LoadRemoteKeyringClient(ctx, store)
	if err != nil {
		return nil, err
	}
	return client.ReadRemoteDeviceLogs(since, requestID), nil
}
