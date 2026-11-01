// Written by AI on 2026.11.01 by model gpt-6.1-sol.
const HOST = 'com.agentkeyring.browser';
let profile, port;
const token = (tab, top, frame) => btoa(JSON.stringify({profile, tab: tab.id,
  frame: frame.frameId, document: frame.documentId, top: top.documentId})).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
const decode = value => JSON.parse(atob(value.replaceAll('-', '+').replaceAll('_', '/')));
const page = url => /^https?:\/\//.test(url || '');
const matches = (url, sites) => {
  let actual;
  try { actual = new URL(url); } catch { return false; }
  const local = ['127.0.0.1', '[::1]', 'localhost'].includes(actual.hostname);
  if (actual.username || actual.password || (actual.protocol !== 'https:' && !(local && actual.protocol === 'http:'))) return false;
  return sites.some(site => {
    try {
      const saved = new URL(site.includes('://') ? site : 'https://' + site);
      return local ? saved.origin === actual.origin : saved.protocol === 'https:' && saved.port === actual.port &&
        (actual.hostname === saved.hostname || actual.hostname.endsWith('.' + saved.hostname));
    } catch { return false; }
  });
};
async function target(value) {
  const t = decode(value);
  if (t.profile !== profile || !Number.isInteger(t.tab) || !Number.isInteger(t.frame)) throw Error();
  const [tab, top, frame] = await Promise.all([chrome.tabs.get(t.tab),
    chrome.webNavigation.getFrame({tabId: t.tab, frameId: 0}),
    chrome.webNavigation.getFrame({tabId: t.tab, frameId: t.frame})]);
  if (!top || !frame || top.documentId !== t.top || frame.documentId !== t.document ||
      (frame.documentLifecycle && frame.documentLifecycle !== 'active') || !page(frame.url)) throw Error();
  return {tab, top: {...top, frameId: 0}, frame: {...frame, frameId: t.frame}};
}
const metadata = (tab, top, frame) => ({target: token(tab, top, frame), url: frame.url,
  title: tab.title || '', browser: 'Chromium', profile});
const attach = (tab, document) => chrome.scripting.executeScript({
  target: {tabId: tab.id, documentIds: [document.documentId]}, files: ['page.js'], world: 'ISOLATED'
});
async function tabs() {
  const result = [];
  for (const tab of await chrome.tabs.query({})) {
    if (!page(tab.url)) continue;
    const top = await chrome.webNavigation.getFrame({tabId: tab.id, frameId: 0});
    if (top?.documentId) result.push(metadata(tab, top, {...top, frameId: 0}));
  }
  return {tabs: result};
}
async function handle(command) {
  if (command.action === 'ACTION_TABS') return tabs();
  let current;
  try { current = await target(command.target); }
  catch { return {error: 'The tab or document changed. Run tabs and inspect its current fields.'}; }
  const {tab, top, frame} = current;
  if (command.action === 'ACTION_FIELDS') {
    const controls = [];
    for (const f of await chrome.webNavigation.getAllFrames({tabId: tab.id})) {
      if (frame.frameId !== 0 && f.frameId !== frame.frameId) continue;
      if (!page(f.url) || (f.documentLifecycle && f.documentLifecycle !== 'active')) continue;
      try {
        await attach(tab, f);
        const result = await chrome.tabs.sendMessage(tab.id, {action: 'fields'}, {documentId: f.documentId});
        for (const control of result.controls || []) controls.push({...control, target: token(tab, top, f)});
      } catch {
        if (f.frameId === frame.frameId) return {error: 'This page is still loading or cannot be inspected. Run fields again when it is ready.'};
      }
    }
    await target(command.target);
    return {inspection: {tab: metadata(tab, top, frame), controls}};
  }
  if (command.action !== 'ACTION_PREPARE' && command.action !== 'ACTION_FILL') return {error: 'Unsupported browser operation.'};
  if (command.action === 'ACTION_FILL' && !matches(frame.url, command.sites || []))
    return {error: "This frame is outside the saved login's destinations."};
  try {
    await attach(tab, frame);
    const result = await chrome.tabs.sendMessage(tab.id, {action: command.action === 'ACTION_FILL' ? 'fill' : 'prepare',
      fields: command.fields || [], submit: command.submit, values: command.values,
      origin: new URL(frame.url).origin}, {documentId: frame.documentId});
    if (result.error) return {error: result.error};
    if (command.action === 'ACTION_PREPARE') {
      await target(command.target);
      return {inspection: {tab: metadata(tab, top, frame)}};
    }
    return {fill: result.fill};
  } catch {
    return command.action === 'ACTION_FILL' ? {fill: {outcome: 2,
      detail: 'The browser did not confirm the fill. This step is recorded; repeating it will not submit again. Run tabs and inspect the page before using --again.'}} :
      {error: 'This document cannot be filled or has changed. Run tabs and fields again.'};
  } finally { command.values?.fill(''); }
}
async function connect() {
  const saved = await chrome.storage.local.get('profile');
  profile = saved.profile || crypto.randomUUID().replaceAll('-', '');
  if (!saved.profile) await chrome.storage.local.set({profile});
  port = chrome.runtime.connectNative(HOST);
  port.postMessage({profile, browser: 'Chromium'});
  port.onMessage.addListener(async command => {
    let result;
    try { result = await handle(command); }
    catch { result = {error: 'The browser could not complete that operation. Run tabs again.'}; }
    try { port.postMessage({id: command.id, ...result}); } catch {}
  });
  port.onDisconnect.addListener(() => { void chrome.runtime.lastError; setTimeout(connect, 1000); });
}
connect();
