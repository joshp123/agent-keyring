// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package receiver

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/coder/websocket"
	pb "github.com/joshp123/agent-keyring/gen/go/agentkeyring/v1"
	"github.com/joshp123/agent-keyring/internal/authority"
)

type debugger struct {
	connection *websocket.Conn
	sequence   int
	session    string
}

func (d *debugger) call(ctx context.Context, method string, params any, result any) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	d.sequence++
	data, err := json.Marshal(struct {
		ID      int    `json:"id"`
		Method  string `json:"method"`
		Params  any    `json:"params"`
		Session string `json:"sessionId,omitempty"`
	}{d.sequence, method, params, d.session})
	if err != nil {
		return err
	}
	defer clear(data)
	if err = d.connection.Write(ctx, websocket.MessageText, data); err != nil {
		return errors.New("The browser connection was lost.")
	}
	for {
		_, data, err = d.connection.Read(ctx)
		if err != nil {
			return errors.New("The browser did not confirm the operation.")
		}
		var reply struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		err = json.Unmarshal(data, &reply)
		clear(data)
		if err != nil {
			return errors.New("The browser returned an invalid reply.")
		}
		if reply.ID != d.sequence {
			continue
		}
		if len(reply.Error) > 0 {
			return errors.New("The browser refused the operation or its document changed.")
		}
		if result != nil {
			return json.Unmarshal(reply.Result, result)
		}
		return nil
	}
}

type frame struct {
	ID     string `json:"id"`
	Loader string `json:"loaderId"`
	Origin string `json:"securityOrigin"`
	URL    string `json:"url"`
}
type frameTree struct {
	Frame    frame       `json:"frame"`
	Children []frameTree `json:"childFrames"`
}

func findFrame(tree frameTree, id string) (frame, bool) {
	if id == "" || tree.Frame.ID == id {
		return tree.Frame, true
	}
	for _, child := range tree.Children {
		if f, ok := findFrame(child, id); ok {
			return f, true
		}
	}
	return frame{}, false
}
func (d *debugger) frame(ctx context.Context, id string) (frame, error) {
	var reply struct {
		Tree frameTree `json:"frameTree"`
	}
	if err := d.call(ctx, "Page.getFrameTree", struct{}{}, &reply); err != nil {
		return frame{}, err
	}
	f, ok := findFrame(reply.Tree, id)
	if !ok {
		return f, errors.New("The requested frame is not attached to this tab. Cross-process frames are not supported yet.")
	}
	return f, nil
}
func endpoint(raw string) (*url.URL, error) {
	if !strings.Contains(raw, "://") {
		raw = "http://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return nil, errors.New("Supply a local browser debugging URL, such as http://127.0.0.1:9222.")
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Scheme != "http" && u.Scheme != "ws") {
		return nil, errors.New("Use a local http or ws browser debugging endpoint without credentials or query parameters.")
	}
	if u.Hostname() != "127.0.0.1" && u.Hostname() != "::1" && u.Hostname() != "localhost" {
		return nil, errors.New("The Chromium receiver requires a loopback endpoint on this machine.")
	}
	if u.Port() == "" {
		return nil, errors.New("The browser debugging endpoint needs its port.")
	}
	if u.Scheme == "http" && u.Path != "" && u.Path != "/" {
		return nil, errors.New("Use the browser endpoint, not a page URL.")
	}
	if u.Hostname() == "localhost" {
		u.Host = net.JoinHostPort("127.0.0.1", u.Port())
	}
	return u, nil
}
func connectBrowser(ctx context.Context, u *url.URL) (*debugger, error) {
	address := u.String()
	if u.Scheme == "http" {
		request, _ := http.NewRequestWithContext(ctx, "GET", strings.TrimSuffix(u.String(), "/")+"/json/version", nil)
		client := http.Client{Timeout: 4 * time.Second, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect refused") }}
		response, err := client.Do(request)
		if err != nil {
			return nil, errors.New("Cannot reach the browser debugging endpoint.")
		}
		defer response.Body.Close()
		var version struct {
			Address string `json:"webSocketDebuggerUrl"`
		}
		if response.StatusCode != 200 || json.NewDecoder(io.LimitReader(response.Body, 65536)).Decode(&version) != nil {
			return nil, errors.New("The endpoint did not return a browser debugging address.")
		}
		address = version.Address
	}
	ws, err := url.Parse(address)
	if err != nil || ws.Scheme != "ws" || ws.Host != u.Host || !strings.HasPrefix(ws.Path, "/devtools/browser/") || ws.User != nil || ws.RawQuery != "" || ws.Fragment != "" {
		return nil, errors.New("The debugging address does not belong to the validated local browser endpoint.")
	}
	connection, _, err := websocket.Dial(ctx, address, &websocket.DialOptions{HTTPClient: &http.Client{Transport: &http.Transport{Proxy: nil}, Timeout: 5 * time.Second}})
	if err != nil {
		return nil, errors.New("Cannot attach to this browser. Use its browser debugging endpoint.")
	}
	connection.SetReadLimit(1 << 20)
	return &debugger{connection: connection}, nil
}
func allowedOrigin(origin string, sites []string) bool {
	actual, err := url.Parse(origin)
	if err != nil || actual.Hostname() == "" || actual.User != nil {
		return false
	}
	loopback := actual.Hostname() == "127.0.0.1" || actual.Hostname() == "::1" || actual.Hostname() == "localhost"
	if actual.Scheme != "https" && !(actual.Scheme == "http" && loopback) {
		return false
	}
	for _, site := range sites {
		if !strings.Contains(site, "://") {
			site = "https://" + site
		}
		saved, err := url.Parse(site)
		if err != nil || saved.Hostname() == "" || saved.User != nil {
			continue
		}
		host := strings.ToLower(actual.Hostname())
		savedHost := strings.ToLower(saved.Hostname())
		if loopback {
			if saved.Scheme == actual.Scheme && saved.Host == actual.Host {
				return true
			}
			continue
		}
		if saved.Scheme == "https" && (host == savedHost || strings.HasSuffix(host, "."+savedHost)) && actual.Port() == saved.Port() {
			return true
		}
	}
	return false
}
func tabLock(ctx context.Context, identity, tab string) (func(), error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	directory := filepath.Join(home, ".cache/agent-keyring/tab-locks")
	if err = os.MkdirAll(directory, 0700); err != nil {
		return nil, errors.New("Cannot create the local browser lock directory.")
	}
	path := filepath.Join(directory, hex.EncodeToString(Digest(identity, tab))+".lock")
	fd, err := syscall.Open(path, syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, errors.New("Cannot lock the selected browser tab.")
	}
	file := os.NewFile(uintptr(fd), path)
	for {
		err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() { syscall.Flock(fd, syscall.LOCK_UN); file.Close() }, nil
		}
		if err != syscall.EWOULDBLOCK {
			file.Close()
			return nil, errors.New("Cannot lock the selected browser tab.")
		}
		select {
		case <-ctx.Done():
			file.Close()
			return nil, ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}
func fillResult(outcome pb.FillOutcome, detail string) *pb.FillResult {
	return &pb.FillResult{Outcome: outcome, Detail: detail}
}
func Fill(ctx context.Context, client authority.Client, lease *pb.Lease, request *pb.FillRequest) *pb.FillResult {
	if lease.Purpose != pb.Purpose_PURPOSE_BROWSER_SIGN_IN {
		return fillResult(6, "This lease does not approve browser sign-in.")
	}
	target := request.GetTarget().GetChromium()
	if target == nil {
		return fillResult(5, "This browser target is not supported.")
	}
	u, err := endpoint(target.Endpoint)
	if err != nil {
		return fillResult(4, err.Error())
	}
	identity, err := browserIdentity(u.Port())
	if err != nil {
		return fillResult(5, err.Error())
	}
	unlock, err := tabLock(ctx, identity, target.TargetId)
	if err != nil {
		return fillResult(4, err.Error())
	}
	defer unlock()
	currentIdentity, err := browserIdentity(u.Port())
	if err != nil || identity != currentIdentity {
		return fillResult(7, "The browser instance changed. Inspect its current tab before trying again.")
	}
	fields := append([]*pb.FieldBinding(nil), request.Fields...)
	sort.Slice(fields, func(i, j int) bool { return fields[i].Field < fields[j].Field })
	parts := []string{lease.LeaseId, "fill", identity, u.Host, target.TargetId, target.FrameId, target.LoaderId, request.SubmitSelector}
	selected := []pb.CredentialField{}
	for _, binding := range fields {
		parts = append(parts, fmt.Sprint(binding.Field), binding.Selector)
		selected = append(selected, binding.Field)
	}
	record, err := client.Operation(ctx, lease.LeaseId, Digest(parts...), request.OperationId)
	if err != nil {
		return fillResult(6, err.Error())
	}
	if record != nil {
		return previousFill(record)
	}
	d, err := connectBrowser(ctx, u)
	if err != nil {
		return fillResult(4, err.Error())
	}
	defer d.connection.CloseNow()
	var info struct {
		Info struct {
			Type string `json:"type"`
		} `json:"targetInfo"`
	}
	if err = d.call(ctx, "Target.getTargetInfo", map[string]any{"targetId": target.TargetId}, &info); err != nil || info.Info.Type != "page" {
		return fillResult(4, "The selected tab is not a browser page.")
	}
	var attached struct {
		Session string `json:"sessionId"`
	}
	if err = d.call(ctx, "Target.attachToTarget", map[string]any{"targetId": target.TargetId, "flatten": true}, &attached); err != nil {
		return fillResult(4, err.Error())
	}
	d.session = attached.Session
	f, err := d.frame(ctx, target.FrameId)
	if err != nil {
		return fillResult(4, err.Error())
	}
	if target.LoaderId != "" && f.Loader != target.LoaderId {
		return fillResult(7, "The page changed since you inspected it. Inspect the current page before filling.")
	}
	if !client.Remote && !allowedOrigin(f.Origin, lease.Sites) {
		return fillResult(3, "This frame's actual site is outside the saved login's destinations.")
	}
	var world struct {
		ID int `json:"executionContextId"`
	}
	if err = d.call(ctx, "Page.createIsolatedWorld", map[string]any{"frameId": f.ID, "worldName": "agent-keyring-" + NewID()}, &world); err != nil {
		return fillResult(5, "This frame cannot host a supported fill operation.")
	}
	bindings := []map[string]any{}
	for _, b := range fields {
		bindings = append(bindings, map[string]any{"field": int32(b.Field), "selector": b.Selector})
	}
	var prepared struct {
		Result struct {
			ID    string `json:"objectId"`
			Value any    `json:"value"`
		} `json:"result"`
		Exception json.RawMessage `json:"exceptionDetails"`
	}
	err = d.call(ctx, "Runtime.callFunctionOn", map[string]any{"executionContextId": world.ID, "functionDeclaration": prepareScript, "arguments": []map[string]any{{"value": bindings}, {"value": request.SubmitSelector}, {"value": f.Origin}}, "returnByValue": false}, &prepared)
	if err != nil || len(prepared.Exception) > 0 || prepared.Result.ID == "" {
		return fillResult(4, "A field or submit selector is missing, ambiguous or unsuitable. Use one editable input per field and an explicit submit control in the same form.")
	}
	currentFrame, err := d.frame(ctx, f.ID)
	if err != nil || currentFrame.Loader != f.Loader || currentFrame.Origin != f.Origin {
		return fillResult(7, "The target document changed during preparation.")
	}
	response, err := client.Begin(ctx, &pb.BeginOperationRequest{LeaseId: lease.LeaseId, OperationDigest: Digest(parts...), Kind: pb.OperationKind_OPERATION_KIND_FILL, Fields: selected, RequestId: request.OperationId})
	if err != nil {
		return fillResult(6, err.Error())
	}
	if record := response.GetAlreadyStarted(); record != nil {
		return previousFill(record)
	}
	values, sites, err := Delivered(ctx, client, lease, response, selected)
	if err != nil {
		return fillResult(2, err.Error())
	}
	defer ClearValues(values)
	if !allowedOrigin(f.Origin, sites) {
		client.Finish(context.WithoutCancel(ctx), &pb.FinishOperationRequest{LeaseId: lease.LeaseId, OperationId: response.OperationId, Outcome: &pb.FinishOperationRequest_Fill{Fill: pb.FillOutcome_FILL_OUTCOME_SITE_MISMATCH}})
		return fillResult(3, "This frame's actual site is outside the signed login's saved destinations.")
	}
	currentFrame, err = d.frame(ctx, f.ID)
	if err != nil || currentFrame.Loader != f.Loader || currentFrame.Origin != f.Origin {
		return fillResult(7, "The target document changed while the delivery was being verified.")
	}
	payload := []string{}
	for _, field := range selected {
		payload = append(payload, Value(values, field))
	}
	defer clear(payload)
	var action struct {
		Result struct {
			Value string `json:"value"`
		} `json:"result"`
		Exception json.RawMessage `json:"exceptionDetails"`
	}
	err = d.call(ctx, "Runtime.callFunctionOn", map[string]any{"objectId": prepared.Result.ID, "functionDeclaration": fillScript, "arguments": []map[string]any{{"value": payload}}, "returnByValue": true}, &action)
	outcome := pb.FillOutcome_FILL_OUTCOME_SUBMITTED
	detail := "Submitted this sign-in step and cleared remaining values. Inspect the page to confirm sign-in."
	if err != nil || len(action.Exception) > 0 || action.Result.Value != "submitted" {
		outcome = pb.FillOutcome_FILL_OUTCOME_UNCERTAIN
		detail = "The fill result is uncertain. Inspect the page before using --again."
	}
	if !d.cleanup(ctx, prepared.Result.ID, f, err == nil && len(action.Exception) == 0 && action.Result.Value == "submitted") {
		outcome = pb.FillOutcome_FILL_OUTCOME_CLEANUP_FAILED
		detail = "Could not confirm cleanup. Values may remain; close the affected tab with your browser tools without reading its fields."
	}
	if err = client.Finish(context.WithoutCancel(ctx), &pb.FinishOperationRequest{LeaseId: lease.LeaseId, OperationId: response.OperationId, Outcome: &pb.FinishOperationRequest_Fill{Fill: outcome}}); err != nil {
		return fillResult(2, "The browser attempt ended, but its receipt was not saved. Inspect the page; a retry must not submit again.")
	}
	result := fillResult(outcome, detail)
	result.FieldsFilled = selected
	return result
}
func (d *debugger) cleanup(ctx context.Context, object string, previous frame, clearedBeforeNavigation bool) bool {
	// Cleanup still runs after interruption of the calling shell.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 8*time.Second)
	defer cancel()
	var reply struct {
		Result struct {
			Value bool `json:"value"`
		} `json:"result"`
		Exception json.RawMessage `json:"exceptionDetails"`
	}
	err := d.call(ctx, "Runtime.callFunctionOn", map[string]any{"objectId": object, "functionDeclaration": cleanupScript, "returnByValue": true}, &reply)
	if err == nil && len(reply.Exception) == 0 && reply.Result.Value {
		return true
	}
	// A destroyed context counts only after the browser confirms the old loader
	// is gone; a URL change by itself never establishes cleanup.
	current, err := d.frame(ctx, previous.ID)
	return clearedBeforeNavigation && err == nil && current.Loader != "" && current.Loader != previous.Loader
}

const prepareScript = `function(bindings, selector, origin) {
 if (location.origin !== origin || !bindings.length) throw Error();
 const query = s => { const all=document.querySelectorAll(s); if(all.length!==1)throw Error(); return all[0]; };
 const visible = e => e.isConnected && !e.disabled && !e.readOnly && e.getClientRects().length>0 && getComputedStyle(e).visibility==='visible';
 const submit=query(selector);
 if(!visible(submit) || !(submit instanceof HTMLButtonElement || (submit instanceof HTMLInputElement && ['submit','button'].includes(submit.type))))throw Error();
 if(!submit.form)throw Error();
 const fields=bindings.map(b=>{ const e=query(b.selector); if(!(e instanceof HTMLInputElement)||!visible(e)||e.form!==submit.form)throw Error();
 if(b.field===2 ? e.type!=='password' : !['text','email','tel','number'].includes(e.type))throw Error();
 return e; });
 if(new Set(fields).size!==fields.length || bindings.some((b,i)=>i&&bindings[i-1].field===b.field))throw Error();
 return {fields, bindings, submit, selector, origin, query, visible, values:[], setter:Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set};
}`
const fillScript = `function(values) {
 if(location.origin!==this.origin || values.length!==this.fields.length)throw Error();
 const validate=()=>this.fields.every((e,i)=>this.visible(e)&&this.query(this.bindings[i].selector)===e&&e.form===this.submit.form) && this.visible(this.submit)&&this.query(this.selector)===this.submit;
 if(!validate())throw Error(); this.values=values;
 for(let i=0;i<this.fields.length;i++){if(!validate())throw Error();this.setter.call(this.fields[i],values[i]);this.fields[i].dispatchEvent(new Event('input',{bubbles:true}));this.fields[i].dispatchEvent(new Event('change',{bubbles:true}));}
 if(!validate())throw Error();
 try { this.submit.click(); }
 finally { for(const e of this.fields){if(this.values.includes(e.value))this.setter.call(e,'');} }
 this.cleared=this.fields.every(e=>!this.values.includes(e.value)||e.value==='');
 return this.cleared ? 'submitted' : 'cleanup-failed';
}`
const cleanupScript = `function() {
 const inputs=[...this.fields,...document.querySelectorAll('input')];
 for(const e of inputs){if(this.values.includes(e.value))this.setter.call(e,'');}
 const cleared=inputs.every(e=>!this.values.includes(e.value)||e.value==='');this.values=[];return cleared;
}`

func previousFill(record *pb.OperationRecord) *pb.FillResult {
	switch record.GetFill() {
	case pb.FillOutcome_FILL_OUTCOME_SUBMITTED:
		return fillResult(1, "This step was already submitted; it was not submitted again.")
	case pb.FillOutcome_FILL_OUTCOME_CLEANUP_FAILED:
		return fillResult(8, "The earlier attempt could not confirm cleanup. Close the affected tab without reading its fields.")
	default:
		return fillResult(2, "The earlier fill is uncertain or already finished. Inspect the page before deliberately repeating it with --again.")
	}
}
