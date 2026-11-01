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
    if (!visible(submit) ||
        !(submit instanceof HTMLButtonElement || (submit instanceof HTMLInputElement && ['submit', 'button'].includes(submit.type)))) throw Error();
    const fields = message.fields.map(b => {
      const e = query(b.selector);
      if (!(e instanceof HTMLInputElement) || !visible(e) || e.matches(':disabled') || e.readOnly || (e.form && submit.form && e.form !== submit.form)) throw Error();
      if (b.field === 'CREDENTIAL_FIELD_PASSWORD' ? e.type !== 'password' : !['text', 'email', 'tel', 'number'].includes(e.type)) throw Error();
      return e;
    });
    if (new Set(fields).size !== fields.length || new Set(message.fields.map(b => b.field)).size !== fields.length) throw Error();
    const types = fields.map(e => e.type);
    return {fields, submit, valid: () => location.origin === message.origin &&
      query(message.submit) === submit && visible(submit) &&
      fields.every((e, i) => query(message.fields[i].selector) === e && visible(e) && !e.matches(':disabled') && !e.readOnly && e.type === types[i] && (!e.form || !submit.form || e.form === submit.form))};
  };
  const fill = async (message, prepared, respond) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    const changed = e => {
      e.dispatchEvent(new Event('input', {bubbles: true, composed: true}));
      e.dispatchEvent(new Event('change', {bubbles: true, composed: true}));
    };
    const written = [];
    const deadline = performance.now() + 10000;
    const pause = () => new Promise(resolve => setTimeout(resolve, 50));
    const originalURL = location.href;
    const originalAlerts = new Map([...document.querySelectorAll('[role="alert"], [aria-live="assertive"]')].map(e => [e, visible(e) ? text(e) : '']));
    let finished = false, clicked = false, submitEvent, serialized = false;
    const onSubmit = event => { if (event.isTrusted) submitEvent = event; };
    const onFormData = event => { if (event.isTrusted) serialized = true; };
    const onDeparture = event => { if (event.isTrusted) finish(clicked ? 1 : 2); };
    const observations = () => {
      const result = [];
      if (location.href !== originalURL) result.push('The address changed.');
      const removed = prepared.fields.filter(e => !e.isConnected).length;
      if (removed) result.push((removed === prepared.fields.length ? 'The' : 'Some') + ' filled fields were removed or replaced.');
      if ([...document.querySelectorAll('[role="alert"], [aria-live="assertive"]')].some(e => visible(e) && text(e) && text(e) !== originalAlerts.get(e))) result.push('The page displayed an alert.');
      if (!result.length) result.push('The address and filled fields stayed in place.');
      return result.join(' ');
    };
    const finish = (outcome, detail) => {
      if (finished) return;
      finished = true;
      const observed = outcome === 2 ? observations() : '';
      removeEventListener('pagehide', onDeparture);
      prepared.submit.form?.removeEventListener('submit', onSubmit);
      prepared.submit.form?.removeEventListener('formdata', onFormData);
      let cleaned = true;
      for (const e of written) {
        try { setter.call(e, ''); changed(e); if (e.value !== '') cleaned = false; }
        catch { cleaned = false; }
      }
      message.values.fill('');
      respond({fill: {outcome: cleaned ? outcome : 8,
        detail: !cleaned ? 'Cleanup could not be confirmed. Close this tab without reading its fields.' :
          detail || (outcome === 1 ? 'Submitted this sign-in step and cleared remaining values. Inspect the page to confirm sign-in.' :
            'The fill result is uncertain. ' + observed + ' Values were cleared. This step is recorded; repeating it will not submit again. Inspect the page before using --again.')}});
    };
    try {
      for (let i = 0; i < prepared.fields.length; i++) {
        if (!prepared.valid()) throw Error();
        const e = prepared.fields[i];
        e.focus({preventScroll: true});
        setter.call(e, message.values[i]);
        written.push(e);
        changed(e);
        e.blur();
      }
      while (prepared.submit.matches(':disabled') && performance.now() < deadline) {
        if (!prepared.valid()) throw Error();
        await pause();
      }
      if (!prepared.valid()) throw Error();
      if (prepared.submit.matches(':disabled')) {
        finish(4, 'The submit control stayed disabled. Values were cleared without clicking it. Inspect the page before trying again.');
        return;
      }
      const form = prepared.submit.form;
      if (form && prepared.submit.type === 'submit' && !form.noValidate && !prepared.submit.formNoValidate && !form.checkValidity()) {
        finish(4, 'The form needs another field or a valid value. Values were cleared without submitting. Inspect the page before trying again.');
        return;
      }
      form?.addEventListener('submit', onSubmit);
      form?.addEventListener('formdata', onFormData);
      addEventListener('pagehide', onDeparture);
      clicked = true;
      prepared.submit.click();
      // Native form data has been captured before click returns. Scripted
      // handlers may retain even detached inputs and read them later. Only the
      // browser's native submission or document departure confirms consumption.
      while (!finished) {
        if (serialized && submitEvent && !submitEvent.defaultPrevented) {
          finish(1);
        } else if (performance.now() >= deadline) {
          finish(2);
        } else {
          await pause();
        }
      }
    } catch { finish(2); }
  };
  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id) return;
    if (message.action === 'fields') { respond({controls: controls()}); return; }
    let prepared;
    try { prepared = prepare(message); }
    catch { respond({error: 'A field or submit selector is missing, ambiguous or unsuitable. Run fields again.'}); return; }
    if (message.action === 'prepare') { respond({ready: true}); return; }
    if (message.action !== 'fill' || message.values?.length !== prepared.fields.length) return;
    void fill(message, prepared, respond);
    return true;
  });
})();
