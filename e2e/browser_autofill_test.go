// Written by AI on 2026.11.27 by model gpt-6.2-sol.
package e2e

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	pb "github.com/opentrawl/agent-keyring/gen/go/agentkeyring/v2"
	"github.com/opentrawl/agent-keyring/internal/authority"
	"github.com/opentrawl/agent-keyring/internal/browserbridge"
	"google.golang.org/protobuf/encoding/protojson"
)

const browserProfile = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type nativeHostHarness struct {
	input  io.WriteCloser
	output io.ReadCloser
}

func startBrowserHost(t *testing.T, cli testComputer) nativeHostHarness {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 40*time.Second)
	t.Cleanup(cancel)
	cmd := cli.buildComputerCommand(ctx, "chrome-extension://"+browserbridge.ExtensionID+"/")
	input, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stderr := newBuffer()
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cancel()
		if err := cmd.Wait(); err != nil && stderr.String() != "" {
			t.Errorf("browser native host: %v\n%s", err, stderr.String())
		}
	})
	extension := nativeHostHarness{input, output}
	extension.sendBrowserFixtureReply(t, &browserbridge.Response{Profile: browserProfile})
	eventually(t, "native browser host socket", func() bool {
		info, err := os.Stat(filepath.Join(cli.state, "browsers", browserProfile+".sock"))
		if errors.Is(err, os.ErrNotExist) {
			return false
		}
		if err != nil {
			t.Fatal(err)
		}
		return info.Mode()&os.ModeSocket != 0
	})
	return extension
}

func (b nativeHostHarness) sendBrowserFixtureReply(t *testing.T, response *browserbridge.Response) {
	t.Helper()
	data, err := protojson.Marshal(response)
	if err != nil {
		t.Fatal(err)
	}
	frame := binary.LittleEndian.AppendUint32(nil, uint32(len(data)))
	if _, err := b.input.Write(append(frame, data...)); err != nil {
		t.Fatal(err)
	}
}

func (b nativeHostHarness) readBrowserFixtureRequest(t *testing.T, action browserbridge.Action) *browserbridge.ExtensionRequest {
	t.Helper()
	var size uint32
	if err := binary.Read(b.output, binary.LittleEndian, &size); err != nil {
		t.Fatal(err)
	}
	if size == 0 || size > authority.MaxFrame {
		t.Fatalf("invalid native message size %d", size)
	}
	data := make([]byte, size)
	if _, err := io.ReadFull(b.output, data); err != nil {
		t.Fatal(err)
	}
	request := new(browserbridge.ExtensionRequest)
	if err := protojson.Unmarshal(data, request); err != nil {
		t.Fatal(err)
	}
	if request.Action != action {
		t.Fatalf("native host action: want %s, got %s", action, request.Action)
	}
	return request
}

func fillInBrowser(t *testing.T, cli testComputer, id string) {
	t.Helper()
	extension := startBrowserHost(t, cli)
	target := base64.RawURLEncoding.EncodeToString([]byte(`{"profile":"` + browserProfile + `"}`))
	fill := func(operation string) func() cliProcessResult {
		return cli.beginComputerCommand(t, "fill", id, "--tab", target, "--username", "#username", "--password", "#password",
			"--submit", "#sign-in", "--operation", operation)
	}

	waiting := fill("approved-origin")
	extension.prepareBrowserFixtureTarget(t, target, "https://github.example/sign-in")
	request := extension.readBrowserFixtureRequest(t, browserbridge.Action_ACTION_FILL)
	if request.Target != target || request.Submit != "#sign-in" || !slices.Equal(request.Values, []string{"test@example.net", "pw-github.example"}) {
		t.Fatalf("browser did not receive the approved values and submit control")
	}
	extension.sendBrowserFixtureReply(t, &browserbridge.Response{Id: request.Id,
		Fill: &pb.FillResult{Outcome: pb.FillOutcome_FILL_OUTCOME_SUBMITTED}})
	got := waiting()
	assertSuccess(t, got)
	assertSuccess(t, fill("approved-origin")()) // A repeated operation must not submit again.

	waiting = fill("wrong-origin")
	extension.prepareBrowserFixtureTarget(t, target, "https://elsewhere.example/sign-in")
	assertRefused(t, waiting(), "This frame is outside the approved login's saved destinations")
}

func (b nativeHostHarness) prepareBrowserFixtureTarget(t *testing.T, target, url string) {
	t.Helper()
	request := b.readBrowserFixtureRequest(t, browserbridge.Action_ACTION_PREPARE)
	b.sendBrowserFixtureReply(t, &browserbridge.Response{Id: request.Id, Inspection: &browserbridge.Inspection{
		Tab: &browserbridge.Tab{Target: target, Url: url},
	}})
}
