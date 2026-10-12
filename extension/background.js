// Forwards chat-tab events to Cove's local server on your Mac.
// (Content scripts can't call 127.0.0.1 directly; the extension's service worker can.)

const DEFAULT_PORT = 7777;

async function port() {
  const { port } = await chrome.storage.sync.get({ port: DEFAULT_PORT });
  return Number(port) || DEFAULT_PORT;
}

async function post(event) {
  const url = `http://127.0.0.1:${await port()}/event`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(event),
    });
    await chrome.storage.local.set({ lastStatus: res.ok ? "connected" : `error ${res.status}`, lastAt: Date.now() });
  } catch (e) {
    await chrome.storage.local.set({ lastStatus: "Cove isn't running", lastAt: Date.now() });
  }
}

chrome.runtime.onMessage.addListener((msg) => {
  if (msg && msg.type === "cove-event" && msg.event) post(msg.event);
});
