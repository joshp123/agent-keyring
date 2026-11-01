// Written by AI on 2026.11.01 by model gpt-6.1-sol.
// Dummy website behavior, not extension code. Values are sent only to this site.
(() => {
  const style = new URL(document.currentScript.src).searchParams.get('style');
  function install(form) {
    if (!form) return;
    const action = form.action;
    if (style.includes('formless')) {
      const container = document.createElement('div');
      container.innerHTML = form.innerHTML;
      form.replaceWith(container);
      form = container;
    }
    const button = form.querySelector('button');
    const inputs = [...form.querySelectorAll('input')];
    if (style.includes('stuck')) button.disabled = true;
    if (style.includes('invalid')) {
      const required = document.createElement('input');
      required.required = true;
      required.name = 'another-required-field';
      form.append(required);
    }
    if (style.includes('controlled')) {
      const state = inputs.map(e => e.value);
      inputs.forEach((e, i) => e.addEventListener('input', () => { state[i] = e.value; }));
      setInterval(() => inputs.forEach((e, i) => { e.value = state[i]; }), 100);
    }
    if (style.includes('disabled') || style.includes('blur')) {
      button.disabled = true;
      for (const input of inputs) input.addEventListener(style.includes('blur') ? 'blur' : 'input', () => {
        setTimeout(() => { button.disabled = !inputs.every(e => e.value && e.validity.valid); }, 50);
      });
    }
    if (style.includes('async') || style.includes('formless')) {
      const scriptedButton = style.includes('formless') || style.includes('synthetic-form');
      if (scriptedButton) button.type = 'button';
      (scriptedButton ? button : form).addEventListener(scriptedButton ? 'click' : 'submit', async event => {
        event.preventDefault();
        window.proofFinished = false;
        if (style.includes('early-hash')) location.hash = 'working';
        if (style.includes('early-path')) history.pushState({}, '', '/working');
        if (style.includes('synthetic-pagehide')) dispatchEvent(new PageTransitionEvent('pagehide'));
        if (style.includes('synthetic-form')) {
          form.dispatchEvent(new SubmitEvent('submit'));
          form.dispatchEvent(new FormDataEvent('formdata', {formData: new FormData()}));
        }
        if (style.includes('constructor-formdata')) new FormData(form);
        if (style.includes('early-detach')) form.remove();
        if (style.includes('reattach')) {
          const placeholder = document.createElement('div');
          form.replaceWith(placeholder);
          setTimeout(() => placeholder.replaceWith(form), 100);
        }
        if (style.includes('hide')) form.hidden = true;
        if (style.includes('busy')) inputs.forEach(e => { e.disabled = true; });
        await new Promise(resolve => setTimeout(resolve, 200));
        const data = new URLSearchParams(inputs.map(e => [e.name, e.value]));
        if (style.includes('error')) data.set('password', 'deliberately-wrong-dummy-password');
        const response = await fetch(action, {method: 'POST', body: data});
        window.proofFinished = true;
        if (style.includes('route')) history.pushState({}, '', response.url);
        if (style.includes('swap')) {
          const next = new DOMParser().parseFromString(await response.text(), 'text/html');
          next.querySelectorAll('script').forEach(e => e.remove());
          window.proofOldInputs = [...window.proofOldInputs || [], ...inputs];
          document.title = next.title;
          document.body.replaceChildren(...next.body.childNodes);
          install(document.querySelector('form'));
        } else if (style.includes('error')) {
          const message = document.createElement('p');
          message.setAttribute('role', 'alert');
          message.textContent = 'The dummy sign-in was refused.';
          form.replaceWith(message);
          window.proofOldInputs = inputs;
        } else if (!style.includes('route') && response.ok) {
          location.assign(response.url);
        } else if (!response.ok) {
          const message = document.createElement('p');
          message.setAttribute('role', 'alert');
          message.textContent = 'The dummy sign-in was refused.';
          form.append(message);
        }
      });
    }
  }
  install(document.querySelector('form'));
  window.proofReady = true;
})();
