// Written by AI on 2026.10.31 by model gpt-6.1-sol.
package receiver

import (
	"context"
	"encoding/json"
	"errors"
)

type PageTab struct {
	ID    string `json:"targetId"`
	URL   string `json:"url"`
	Title string `json:"title"`
	Type  string `json:"type"`
}

type PageControl struct {
	Selector     string `json:"selector"`
	Type         string `json:"type"`
	Name         string `json:"name"`
	ID           string `json:"id"`
	Label        string `json:"label"`
	Autocomplete string `json:"autocomplete"`
}

type PageFields struct {
	URL      string        `json:"url"`
	Title    string        `json:"title"`
	Controls []PageControl `json:"controls"`
}

func inspectBrowser(ctx context.Context, raw string) (*debugger, error) {
	address, err := endpoint(raw)
	if err != nil {
		return nil, err
	}
	if _, err = browserIdentity(address.Port()); err != nil {
		return nil, err
	}
	return connectBrowser(ctx, address)
}

func Tabs(ctx context.Context, endpoint string) ([]PageTab, error) {
	browser, err := inspectBrowser(ctx, endpoint)
	if err != nil {
		return nil, err
	}
	defer browser.connection.CloseNow()
	var result struct {
		Tabs []PageTab `json:"targetInfos"`
	}
	if err = browser.call(ctx, "Target.getTargets", struct{}{}, &result); err != nil {
		return nil, err
	}
	pages := []PageTab{}
	for _, tab := range result.Tabs {
		if tab.Type == "page" {
			pages = append(pages, tab)
		}
	}
	return pages, nil
}

func (d *debugger) attachPage(ctx context.Context, target string) error {
	var info struct {
		Info PageTab `json:"targetInfo"`
	}
	if err := d.call(ctx, "Target.getTargetInfo", map[string]any{"targetId": target}, &info); err != nil || info.Info.Type != "page" {
		return errors.New("The selected tab is not a browser page.")
	}
	var attached struct {
		Session string `json:"sessionId"`
	}
	if err := d.call(ctx, "Target.attachToTarget", map[string]any{"targetId": target, "flatten": true}, &attached); err != nil {
		return err
	}
	d.session = attached.Session
	return nil
}

func Fields(ctx context.Context, endpoint, tab string) (*PageFields, error) {
	browser, err := inspectBrowser(ctx, endpoint)
	if err != nil {
		return nil, err
	}
	defer browser.connection.CloseNow()
	if err = browser.attachPage(ctx, tab); err != nil {
		return nil, err
	}
	page, err := browser.frame(ctx, "")
	if err != nil {
		return nil, err
	}
	var world struct {
		ID int `json:"executionContextId"`
	}
	if err = browser.call(ctx, "Page.createIsolatedWorld", map[string]any{"frameId": page.ID, "worldName": "agent-keyring-fields"}, &world); err != nil {
		return nil, err
	}
	var result struct {
		Result struct {
			Value PageFields `json:"value"`
		} `json:"result"`
		Exception json.RawMessage `json:"exceptionDetails"`
	}
	if err = browser.call(ctx, "Runtime.evaluate", map[string]any{"expression": fieldsScript, "contextId": world.ID, "returnByValue": true}, &result); err != nil || len(result.Exception) > 0 {
		return nil, errors.New("Cannot inspect this page's fields. The page may have changed; run fields again.")
	}
	return &result.Result.Value, nil
}

const fieldsScript = `(() => {
 const text = element => {
  if (!element || element.matches('input,textarea,select')) return '';
  const copy=element.cloneNode(true);
  copy.querySelectorAll('input,textarea,select,script,style').forEach(e=>e.remove());
  return copy.textContent.replace(/\s+/g,' ').trim();
 };
 const selector = element => {
  const unique = candidate => document.querySelectorAll(candidate).length===1;
  if (element.id && unique('#'+CSS.escape(element.id))) return '#'+CSS.escape(element.id);
  for (const attribute of ['name','autocomplete']) {
   const value=element.getAttribute(attribute);
   const candidate=element.localName+'['+attribute+'="'+CSS.escape(value||'')+'"]';
   if (value && unique(candidate)) return candidate;
  }
  const path=[];
  for (let node=element;node;node=node.parentElement) {
   const siblings=[...node.parentElement?.children||[]].filter(e=>e.localName===node.localName);
   path.unshift(node.localName+':nth-of-type('+(siblings.indexOf(node)+1)+')');
   if (unique(path.join(' > '))) return path.join(' > ');
  }
 };
 const controls=[...document.querySelectorAll('input,button')].filter(element=>{
  const style=getComputedStyle(element);
  return element.type!=='hidden' && element.getClientRects().length>0 && style.visibility!=='hidden' && style.visibility!=='collapse';
 }).map(element=>({
  selector:selector(element), type:element.type, name:element.name, id:element.id,
  label:element.getAttribute('aria-label') || (element.getAttribute('aria-labelledby')||'').split(/\s+/).map(id=>text(document.getElementById(id))).filter(Boolean).join(' ') || [...element.labels||[]].map(text).join(' ') || (element.localName==='button'?text(element):''),
  autocomplete:element.getAttribute('autocomplete')||''
 }));
 return {url:location.href,title:document.title,controls};
})()`
