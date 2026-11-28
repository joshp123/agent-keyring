// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package browserbridge

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/opentrawl/agent-keyring/internal/authority"
	"github.com/opentrawl/agent-keyring/internal/clientstate"
)

var profileID = regexp.MustCompile(`^[a-f0-9]{32}$`)

func socketDirectory() (string, error) {
	store, err := clientstate.DefaultClientStateStore()
	if err != nil {
		return "", err
	}
	directory := filepath.Join(store.Directory, "browsers")
	if err = os.MkdirAll(directory, 0700); err != nil {
		return "", err
	}
	for _, path := range []string{store.Directory, directory} {
		info, e := os.Lstat(path)
		if e != nil {
			return "", e
		}
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !ok || owner.Uid != uint32(os.Getuid()) || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
			return "", errors.New("Agent Keyring's browser connections must be in your private state directory.")
		}
	}
	return directory, nil
}
func targetProfile(target string) (string, error) {
	raw, err := base64.RawURLEncoding.DecodeString(target)
	var identity struct {
		Profile string `json:"profile"`
	}
	if err != nil || len(raw) > 2048 || json.Unmarshal(raw, &identity) != nil || !profileID.MatchString(identity.Profile) {
		return "", errors.New("Use the complete tab target printed by 'agent-keyring tabs'.")
	}
	return identity.Profile, nil
}
func exchangeBrowserSocketFrames(ctx context.Context, path string, request *Request) (*Response, error) {
	conn, err := (&net.Dialer{Timeout: time.Second}).DialContext(ctx, "unix", path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = conn.Close() }()
	if err = conn.SetDeadline(time.Now().Add(30 * time.Second)); err != nil {
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if err = authority.WriteSocketFrame(conn, request); err != nil {
		return nil, errors.New("The browser helper connection ended.")
	}
	response := new(Response)
	if err = authority.ReadSocketFrame(conn, response); err != nil {
		return nil, errors.New("The browser did not confirm the operation. Inspect before retrying.")
	}
	if response.Error != "" {
		return nil, errors.New(response.Error)
	}
	return response, nil
}
func FetchBrowserInventory(ctx context.Context, request *Request) ([]*Tab, error) {
	directory, err := socketDirectory()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}
	tabs := []*Tab{}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".sock") || !profileID.MatchString(strings.TrimSuffix(entry.Name(), ".sock")) {
			continue
		}
		path := filepath.Join(directory, entry.Name())
		response, e := exchangeBrowserSocketFrames(ctx, path, request)
		if errors.Is(e, syscall.ECONNREFUSED) || errors.Is(e, os.ErrNotExist) {
			_ = os.Remove(path) // Best-effort cleanup of a stale socket.
			continue
		}
		if e != nil {
			return nil, fmt.Errorf("Browser helper unavailable: %w", e)
		}
		tabs = append(tabs, response.Tabs...)
	}
	return tabs, nil
}
func CallBrowserBridge(ctx context.Context, request *Request) (*Response, error) {
	if request.Action == Action_ACTION_FILL && request.Target == "" {
		tabs, err := FetchBrowserInventory(ctx, &Request{Action: Action_ACTION_CANDIDATES, Fill: request.Fill})
		if err != nil {
			return nil, err
		}
		if len(tabs) != 1 {
			return nil, matchingTabError(tabs)
		}
		request.Target = tabs[0].Target
	}
	profile, err := targetProfile(request.Target)
	if err != nil {
		return nil, err
	}
	directory, err := socketDirectory()
	if err != nil {
		return nil, err
	}
	response, err := exchangeBrowserSocketFrames(ctx, filepath.Join(directory, profile+".sock"), request)
	if errors.Is(err, syscall.ECONNREFUSED) || errors.Is(err, os.ErrNotExist) {
		return nil, errors.New("That browser profile is not connected. Open it and run tabs again.")
	}
	return response, err
}

func matchingTabError(tabs []*Tab) error {
	if len(tabs) == 0 {
		return errors.New("No connected tab matches this login. Open its site in a browser with the Agent Keyring extension.")
	}
	clean := func(value string) string {
		return strings.Map(func(r rune) rune {
			if r < 32 || r == 127 {
				return ' '
			}
			return r
		}, value)
	}
	var list strings.Builder
	list.WriteString("More than one tab matches this login. Choose --tab from these targets:")
	for _, tab := range tabs {
		fmt.Fprintf(&list, "\n%s  %s  %s", clean(tab.Target), clean(tab.Url), clean(tab.Title))
	}
	return errors.New(list.String())
}
