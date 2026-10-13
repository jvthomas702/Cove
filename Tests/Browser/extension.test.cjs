const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');

function content({ looking = true, enabled = true, previews = true } = {}) {
  let now = 10000;
  let interval;
  let change;
  const events = [];
  const state = { busy: false, reply: 'Previous reply', prompt: 'Explain the result' };
  const handlers = {};
  const location = { hostname: 'chatgpt.com', pathname: '/c/chat-one', href: 'https://chatgpt.com/c/chat-one' };
  const element = (text) => ({ innerText: text, isConnected: true, getBoundingClientRect: () => ({ width: 50, height: 20 }) });
  const document = {
    title: 'Research chat - ChatGPT', documentElement: {}, visibilityState: looking ? 'visible' : 'hidden',
    hasFocus: () => looking,
    querySelectorAll(selector) {
      if (selector === 'button[data-testid="stop-button"]') return state.busy ? [element('Stop')] : [];
      if (selector.includes('data-message-author-role="assistant"')) return [element(state.reply)];
      if (selector.includes('data-message-author-role="user"')) return [element(state.prompt)];
      return [];
    },
  };
  vm.runInNewContext(fs.readFileSync(path.join(root, 'extension/content.js'), 'utf8'), {
    location, document, Date: { now: () => now },
    chrome: { storage: {
      sync: { get: (defaults, callback) => callback({ ...defaults, enabled, includePreviews: previews }) },
      onChanged: { addListener: (fn) => { change = fn; } },
    }, runtime: { sendMessage: (message) => events.push(JSON.parse(JSON.stringify(message.event))) } },
    setInterval: (fn) => { interval = fn; return 1; }, clearInterval: () => { interval = null; },
    setTimeout: () => 2, clearTimeout() {},
    MutationObserver: class { observe() {} disconnect() {} },
    window: { addEventListener: (name, fn) => { handlers[name] = fn; } },
  });
  return { state, events, location, handlers, change: (c) => change(c, 'sync'), tick: (ms = 400) => { now += ms; interval?.(); } };
}

test('shows live reply updates and keeps watched completions quietly', () => {
  const tab = content();
  tab.state.busy = true; tab.tick();
  assert.equal(tab.events.at(-1).kind, 'running');
  assert.equal(tab.events.at(-1).phase, 'Generating response');
  tab.state.reply = 'A new visible reply'; tab.tick(2100);
  assert.equal(tab.events.at(-1).phase, 'Writing reply');
  assert.equal(tab.events.at(-1).body, 'A new visible reply');
  tab.state.busy = false; tab.tick(); tab.tick(1600);
  assert.equal(tab.events.at(-1).kind, 'done');
  assert.equal(tab.events.at(-1).silent, true);
  assert.equal(tab.events.at(-1).url, 'https://chatgpt.com/c/chat-one');
});

test('long replies keep updating the live preview after the first 160 characters', () => {
  const tab = content(); tab.state.busy = true; tab.tick();
  tab.state.reply = 'Opening paragraph. '.repeat(20) + 'Newest text one'; tab.tick(2100);
  assert.ok(tab.events.at(-1).body.endsWith('Newest text one'));
  tab.state.reply += ' and newest text two'; tab.tick(2100);
  assert.ok(tab.events.at(-1).body.endsWith('and newest text two'));
  assert.ok(tab.events.at(-1).body.length <= 160);
  tab.state.busy = false; tab.tick(); tab.tick(1600);
  assert.ok(tab.events.at(-1).body.startsWith('Opening paragraph.'));
});

test('background completion can notify and opt-out keeps content private', () => {
  const tab = content({ looking: false, previews: false });
  tab.state.busy = true; tab.tick();
  assert.ok(!tab.events.at(-1).body.includes('Explain'));
  tab.state.reply = 'Private response text'; tab.tick(2100);
  assert.equal(tab.events.at(-1).body, '21 characters written');
  tab.state.busy = false; tab.tick(); tab.tick(1600);
  assert.equal(tab.events.at(-1).silent, false);
  assert.ok(!tab.events.at(-1).body.includes('Private'));
});

test('turning off tracking clears live work and does not restart accidentally', () => {
  const tab = content();
  tab.state.busy = true; tab.tick();
  tab.change({ enabled: { newValue: false } });
  assert.equal(tab.events.at(-1).kind, 'clear');
  const count = tab.events.length;
  tab.tick(6000); tab.handlers.pageshow(); tab.tick();
  assert.equal(tab.events.length, count);
  const disabled = content({ enabled: false });
  disabled.state.busy = true; disabled.tick();
  assert.equal(disabled.events.length, 0);
});

test('navigation clears the previous conversation without a fake completion', () => {
  const tab = content();
  tab.state.busy = true; tab.tick();
  tab.location.pathname = '/c/chat-two'; tab.location.href = 'https://chatgpt.com/c/chat-two'; tab.tick();
  assert.equal(tab.events.at(-2).kind, 'clear');
  assert.equal(tab.events.at(-2).id, 'web:chatgpt:chat-one');
  assert.equal(tab.events.at(-1).id, 'web:chatgpt:chat-two');
  assert.ok(!tab.events.some((event) => event.kind === 'done'));
});

test('brief disappearance of stop control does not finish the reply', () => {
  const tab = content(); tab.state.busy = true; tab.tick();
  tab.state.busy = false; tab.tick(); tab.tick(1000);
  tab.state.busy = true; tab.tick();
  assert.ok(!tab.events.some((event) => event.kind === 'done'));
  tab.handlers.pagehide();
  assert.equal(tab.events.at(-1).kind, 'clear');
});

test('service worker isolates tabs and orders start/update/finish with delayed storage', async () => {
  let message, removed;
  const posted = [];
  const storage = { activeTabs: {} };
  vm.runInNewContext(fs.readFileSync(path.join(root, 'extension/background.js'), 'utf8'), {
    chrome: {
      storage: {
        local: { get: async () => storage, set: async (value) => { await new Promise((resolve) => setImmediate(resolve)); Object.assign(storage, value); } },
        sync: { get: async () => ({ port: 7777 }) },
      },
      runtime: { onMessage: { addListener: (fn) => { message = fn; } } },
      tabs: { onRemoved: { addListener: (fn) => { removed = fn; } } },
    },
    AbortController, setTimeout, clearTimeout,
    fetch: async (url, options) => { posted.push(JSON.parse(options.body)); return { ok: true }; },
  });
  const emit = (tab, kind) => message({ type: 'cove-event', event: { id: 'web:chatgpt:same', title: 'Chat', kind } }, { tab: { id: tab } });
  emit(1, 'running'); emit(1, 'running'); emit(1, 'done'); emit(2, 'running');
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(posted.filter((event) => event.id.endsWith(':tab:1')).map((event) => event.kind), ['running', 'running', 'done']);
  assert.equal(posted.find((event) => event.id.endsWith(':tab:2')).kind, 'running');
  removed(2);
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(posted.at(-1).id, 'web:chatgpt:same:tab:2');
  assert.equal(posted.at(-1).kind, 'clear');
});
