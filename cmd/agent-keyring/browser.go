// Written by AI on 2026.11.01 by model gpt-6.1-sol.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"text/tabwriter"

	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/browserbridge"
	"github.com/joshp123/agent-keyring/internal/receiver"
)

func inspectBrowser(ctx context.Context, command string, a arguments) (int, error) {
	options := ""
	if command == "fields" {
		options = "tab"
	}
	if err := a.check(options, ""); err != nil {
		return 2, err
	}
	if len(a.positionals) > 0 || len(a.program) > 0 {
		return 2, errors.New("tabs and fields take no positional arguments. Use fields --tab TARGET to inspect a tab.")
	}
	output := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	if command == "tabs" {
		tabs, err := browserbridge.Inventory(ctx, &browserbridge.Request{Action: browserbridge.Action_ACTION_TABS})
		if err != nil {
			return 1, err
		}
		if len(tabs) == 0 {
			return 1, errors.New("No page tabs are connected. Open a browser profile with the Agent Keyring extension enabled.")
		}
		fmt.Fprintln(output, "TARGET\tBROWSER\tPROFILE\tURL\tTITLE")
		for _, tab := range tabs {
			fmt.Fprintf(output, "%s\t%s\t%s\t%s\t%s\n", safe(tab.Target), safe(tab.Browser), safe(tab.Profile), safe(tab.Url), safe(tab.Title))
		}
	} else {
		if a.options["tab"] == "" {
			return 2, errors.New("fields needs --tab TARGET. Run 'agent-keyring tabs' to choose the page.")
		}
		response, err := browserbridge.Call(ctx, &browserbridge.Request{Action: browserbridge.Action_ACTION_FIELDS, Target: a.options["tab"]})
		if err != nil {
			return 1, err
		}
		inspection := response.GetInspection()
		if inspection.GetTab() == nil {
			return 1, errors.New("The browser did not identify that page. Run tabs again.")
		}
		fmt.Fprintln(output, "Page:", safe(inspection.Tab.Url))
		fmt.Fprintln(output, "Title:", safe(inspection.Tab.Title))
		fmt.Fprintln(output, "TARGET\tSELECTOR\tTYPE\tNAME\tID\tLABEL\tAUTOCOMPLETE")
		for _, field := range inspection.Controls {
			fmt.Fprintf(output, "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", safe(field.Target), safe(field.Selector), safe(field.Type), safe(field.Name), safe(field.Id), safe(field.Label), safe(field.Autocomplete))
		}
		if len(inspection.Controls) == 0 {
			fmt.Fprintln(output, "No visible inputs or buttons.")
		}
	}
	return 0, output.Flush()
}

func fillBrowser(ctx context.Context, a arguments) (int, error) {
	if err := a.check("tab username password code submit operation", "again"); err != nil {
		return 2, err
	}
	lease, err := a.one()
	if err != nil {
		return 2, err
	}
	if len(a.program) > 0 {
		return 2, errors.New("fill takes selectors, not a command after --.")
	}
	if a.options["submit"] == "" {
		return 2, errors.New("fill needs --submit CSS. Run tabs and fields to inspect the sign-in form.")
	}
	key, err := receiver.OperationKey(a.options["operation"], a.flags["again"])
	if err != nil {
		return 2, err
	}
	command := &browserbridge.FillCommand{LeaseId: lease, OperationId: key, Submit: a.options["submit"]}
	for _, binding := range []struct {
		name  string
		field pb.CredentialField
	}{{"username", 1}, {"password", 2}, {"code", 3}} {
		if selector := a.options[binding.name]; selector != "" {
			command.Fields = append(command.Fields, &pb.FieldBinding{Field: binding.field, Selector: selector})
		}
	}
	if len(command.Fields) == 0 {
		return 2, errors.New("Select at least one field with --username, --password or --code.")
	}
	response, err := browserbridge.Call(ctx, &browserbridge.Request{Action: browserbridge.Action_ACTION_FILL, Target: a.options["tab"], Fill: command})
	if err != nil {
		return 1, err
	}
	if response.GetFill() == nil {
		return 1, errors.New("The browser did not confirm the fill. Inspect before retrying.")
	}
	fmt.Fprintln(os.Stderr, safe(response.Fill.Detail))
	if response.Fill.Outcome != pb.FillOutcome_FILL_OUTCOME_SUBMITTED {
		return 1, nil
	}
	return 0, nil
}

// Chrome's --user-data-dir contains this directory too, so an isolated install
// registers only that test browser; it changes no user-wide configuration.
func installNativeHost(userData string) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		return err
	}
	directory, err := filepath.Abs(filepath.Join(userData, "NativeMessagingHosts"))
	if err != nil {
		return err
	}
	if err = os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	manifest := struct {
		Name        string   `json:"name"`
		Description string   `json:"description"`
		Path        string   `json:"path"`
		Type        string   `json:"type"`
		Origins     []string `json:"allowed_origins"`
	}{browserbridge.HostName, "Agent Keyring browser connection", executable, "stdio", []string{"chrome-extension://" + browserbridge.ExtensionID + "/"}}
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(directory, browserbridge.HostName+".json")
	if err = os.WriteFile(path, append(data, '\n'), 0600); err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Registered browser helper:", path)
	return nil
}

func installBrowserHosts() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	var directories []string
	if runtime.GOOS == "darwin" {
		for _, name := range []string{"Google/Chrome", "Google/Chrome for Testing", "Chromium", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data"} {
			directories = append(directories, filepath.Join(home, "Library/Application Support", name))
		}
	} else {
		base := os.Getenv("XDG_CONFIG_HOME")
		if base == "" {
			base = filepath.Join(home, ".config")
		}
		for _, name := range []string{"google-chrome", "google-chrome-for-testing", "chromium", "BraveSoftware/Brave-Browser", "microsoft-edge"} {
			directories = append(directories, filepath.Join(base, name))
		}
	}
	for _, directory := range directories {
		if err = installNativeHost(directory); err != nil {
			return err
		}
	}
	extension, err := extensionPath()
	if err != nil {
		return err
	}
	fmt.Fprintln(os.Stderr, "Load the Agent Keyring extension from:", extension)
	return nil
}

func extensionPath() (string, error) {
	if contents := contentsPath(); contents != "" {
		path := filepath.Join(contents, "Resources/AgentTools/BrowserExtension")
		if _, err := os.Stat(filepath.Join(path, "manifest.json")); err == nil {
			return path, nil
		}
	}
	skill, err := skillPath()
	if err != nil {
		return "", err
	}
	for directory := filepath.Dir(skill); directory != "/" && directory != "."; directory = filepath.Dir(directory) {
		path := filepath.Join(directory, "BrowserExtension")
		if _, err := os.Stat(filepath.Join(path, "manifest.json")); err == nil {
			return path, nil
		}
	}
	return "", errors.New("The browser extension is missing. Reinstall the Agent Keyring CLI package or Mac app.")
}
