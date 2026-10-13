const $ = (id) => document.getElementById(id);

chrome.storage.sync.get({ enabled: true, notifyWhenLooking: false, includePreviews: true, port: 7777 }, (s) => {
  $("enabled").checked = s.enabled;
  $("notifyWhenLooking").checked = s.notifyWhenLooking;
  $("port").value = s.port;
  $("includePreviews").checked = s.includePreviews;
});

$("enabled").addEventListener("change", (e) => chrome.storage.sync.set({ enabled: e.target.checked }));
$("notifyWhenLooking").addEventListener("change", (e) => chrome.storage.sync.set({ notifyWhenLooking: e.target.checked }));
$("includePreviews").addEventListener("change", (e) => chrome.storage.sync.set({ includePreviews: e.target.checked }));
$("port").addEventListener("change", (e) => chrome.storage.sync.set({ port: Number(e.target.value) || 7777 }));

async function check() {
  const { port } = await chrome.storage.sync.get({ port: 7777 });
  try {
    const res = await fetch(`http://127.0.0.1:${port}/health`);
    setStatus(res.ok, res.ok ? "Connected to Cove" : `Cove answered ${res.status}`);
  } catch (e) {
    setStatus(false, "Cove isn't running on this Mac");
  }
}

function setStatus(ok, text) {
  $("dot").style.background = ok ? "#30D158" : "#FF453A";
  $("statusText").textContent = text;
}

$("test").addEventListener("click", async () => {
  const { port } = await chrome.storage.sync.get({ port: 7777 });
  try {
    await fetch(`http://127.0.0.1:${port}/event`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Browser extension connected", body: "Chat tabs will ping the notch when they finish.", kind: "done", source: "chatgpt" }),
    });
    setStatus(true, "Test sent — look at the notch");
  } catch (e) {
    setStatus(false, "Couldn't reach Cove");
  }
});

check();
