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
      if (style.includes('formless')) button.type = 'button';
      (style.includes('formless') ? button : form).addEventListener(style.includes('formless') ? 'click' : 'submit', async event => {
        event.preventDefault();
        window.proofFinished = false;
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
          message.textContent = 'The dummy sign-in was refused.';
          form.replaceWith(message);
          window.proofOldInputs = inputs;
        } else if (!style.includes('route') && response.ok) {
          location.assign(response.url);
        } else if (!response.ok) {
          const message = document.createElement('p');
          message.textContent = 'The dummy sign-in was refused.';
          form.append(message);
        }
      });
    }
  }
  install(document.querySelector('form'));
  window.proofReady = true;
})();
