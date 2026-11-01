// Written by AI on 2026.11.01 by model gpt-6.1-sol.
// Runs in Chrome's isolated extension world, never the page's script world.
(() => {
  if (globalThis.agentKeyringReceiverInstalled) return;
  globalThis.agentKeyringReceiverInstalled = true;
  const visible = e => e.isConnected && e.getClientRects().length > 0 &&
    !['hidden', 'collapse'].includes(getComputedStyle(e).visibility) && getComputedStyle(e).display !== 'none';
  const text = e => {
    if (!e || e.matches('input,textarea,select')) return '';
    const copy = e.cloneNode(true);
    copy.querySelectorAll('input,textarea,select,script,style').forEach(n => n.remove());
    return copy.textContent.replace(/\s+/g, ' ').trim();
  };
  const selector = e => {
    const unique = s => document.querySelectorAll(s).length === 1;
    if (e.id && unique('#' + CSS.escape(e.id))) return '#' + CSS.escape(e.id);
    for (const attribute of ['name', 'autocomplete']) {
      const value = e.getAttribute(attribute);
      const s = e.localName + '[' + attribute + '="' + CSS.escape(value || '') + '"]';
      if (value && unique(s)) return s;
    }
    const path = [];
    for (let n = e; n; n = n.parentElement) {
      const siblings = [...n.parentElement?.children || []].filter(s => s.localName === n.localName);
      path.unshift(n.localName + ':nth-of-type(' + (siblings.indexOf(n) + 1) + ')');
      if (unique(path.join(' > '))) return path.join(' > ');
    }
  };
  const controls = () => [...document.querySelectorAll('input,button')]
    .filter(e => e.type !== 'hidden' && visible(e)).map(e => ({
      selector: selector(e), type: e.type, name: e.name, id: e.id,
      label: e.getAttribute('aria-label') || (e.getAttribute('aria-labelledby') || '').split(/\s+/)
        .map(id => text(document.getElementById(id))).filter(Boolean).join(' ') ||
        [...e.labels || []].map(text).join(' ') || (e.localName === 'button' ? text(e) : ''),
      autocomplete: e.getAttribute('autocomplete') || ''
    }));
  const prepare = message => {
    const query = s => {
      const all = document.querySelectorAll(s);
      if (all.length !== 1) throw Error();
      return all[0];
    };
    if (location.origin !== message.origin || !message.fields?.length) throw Error();
    const submit = query(message.submit);
    if (!visible(submit) || submit.disabled || !submit.form ||
        !(submit instanceof HTMLButtonElement || (submit instanceof HTMLInputElement && ['submit', 'button'].includes(submit.type)))) throw Error();
    const fields = message.fields.map(b => {
      const e = query(b.selector);
      if (!(e instanceof HTMLInputElement) || !visible(e) || e.disabled || e.readOnly || e.form !== submit.form) throw Error();
      if (b.field === 'CREDENTIAL_FIELD_PASSWORD' ? e.type !== 'password' : !['text', 'email', 'tel', 'number'].includes(e.type)) throw Error();
      return e;
    });
    if (new Set(fields).size !== fields.length || new Set(message.fields.map(b => b.field)).size !== fields.length) throw Error();
    const types = fields.map(e => e.type);
    return {fields, submit, valid: () => location.origin === message.origin &&
      query(message.submit) === submit && visible(submit) && !submit.disabled &&
      fields.every((e, i) => query(message.fields[i].selector) === e && visible(e) && !e.disabled && !e.readOnly && e.type === types[i] && e.form === submit.form)};
  };
  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id) return;
    if (message.action === 'fields') { respond({controls: controls()}); return; }
    let prepared;
    try { prepared = prepare(message); }
    catch { respond({error: 'A field or submit selector is missing, ambiguous or unsuitable. Run fields again.'}); return; }
    if (message.action === 'prepare') { respond({ready: true}); return; }
    if (message.action !== 'fill' || message.values?.length !== prepared.fields.length) return;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    let submitted = false, cleaned = true;
    try {
      for (let i = 0; i < prepared.fields.length; i++) {
        if (!prepared.valid()) throw Error();
        setter.call(prepared.fields[i], message.values[i]);
        prepared.fields[i].dispatchEvent(new Event('input', {bubbles: true}));
        prepared.fields[i].dispatchEvent(new Event('change', {bubbles: true}));
      }
      if (!prepared.valid()) throw Error();
      prepared.submit.click();
      submitted = true;
    } catch {} finally {
      for (const e of prepared.fields) {
        try { setter.call(e, ''); if (e.value !== '') cleaned = false; }
        catch { cleaned = false; }
      }
      message.values.fill('');
    }
    respond({fill: {outcome: !cleaned ? 8 : submitted ? 1 : 2,
      detail: !cleaned ? 'Cleanup could not be confirmed. Close this tab without reading its fields.' :
        submitted ? 'Submitted this sign-in step and cleared remaining values. Inspect the page to confirm sign-in.' :
          'The fill result is uncertain. Inspect the page before using --again.'}});
  });
})();
