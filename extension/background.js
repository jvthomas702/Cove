// Keep tab identities distinct and preserve start/update/finish ordering for each activity.
const DEFAULT_PORT = 7777;
const queues = new Map();
const stateReady = chrome.storage.local.get({ activeTabs: {} }).then(({ activeTabs }) => activeTabs);

async function port() {
  const settings = await chrome.storage.sync.get({ port: DEFAULT_PORT });
  const value = Number(settings.port);
  return Number.isInteger(value) && value > 0 && value < 65536 ? value : DEFAULT_PORT;
}

async function post(event) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2500);
  try {
    const res = await fetch(`http://127.0.0.1:${await port()}/event`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(event), signal: controller.signal,
    });
    await chrome.storage.local.set({ lastStatus: res.ok ? "connected" : `error ${res.status}`, lastAt: Date.now() });
  } catch {
    await chrome.storage.local.set({ lastStatus: "Cove isn't running", lastAt: Date.now() });
  } finally { clearTimeout(timeout); }
}

function enqueue(event) {
  const previous = queues.get(event.id) || Promise.resolve();
  const next = previous.catch(() => {}).then(() => post(event));
  queues.set(event.id, next);
  next.finally(() => { if (queues.get(event.id) === next) queues.delete(event.id); }).catch(() => {});
  return next;
}

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== "cove-event" || !message.event || !Number.isInteger(sender.tab?.id)) return;
  const incoming = message.event;
  const event = { ...incoming, id: `${incoming.id}:tab:${sender.tab.id}` };
  // A content script supplies its own URL; validate it again in Cove before offering an Open action.
  stateReady.then(async (activeTabs) => {
    const old = activeTabs[sender.tab.id];
    if (old && old !== event.id) enqueue({ id: old, title: "Chat changed", kind: "clear" });
    if (event.kind === "running") activeTabs[sender.tab.id] = event.id;
    else delete activeTabs[sender.tab.id];
    enqueue(event);
    await chrome.storage.local.set({ activeTabs });
  });
});

chrome.tabs.onRemoved.addListener((tabID) => {
  stateReady.then(async (activeTabs) => {
    const id = activeTabs[tabID];
    delete activeTabs[tabID];
    await chrome.storage.local.set({ activeTabs });
    if (id) enqueue({ id, title: "Chat tab closed", kind: "clear" });
  });
});
