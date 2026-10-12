// Cove — watches a ChatGPT / Claude / Gemini tab and tells the notch when a reply starts and finishes.
//
// How "is it still answering?" is detected: every chat site shows a Stop button while a reply streams,
// and Claude also marks the streaming message. We look for those (several selectors per site, plus a
// generic "any Stop button" fallback) so small redesigns don't break it.

(() => {
  const SITES = {
    "chatgpt.com": "chatgpt",
    "chat.openai.com": "chatgpt",
    "claude.ai": "claude",
    "gemini.google.com": "gemini",
  };
  const site = SITES[location.hostname];
  if (!site) return;

  const NAMES = { chatgpt: "ChatGPT", claude: "Claude", gemini: "Gemini" };

  const BUSY_SELECTORS = {
    chatgpt: [
      'button[data-testid="stop-button"]',
      'button[aria-label*="Stop streaming" i]',
      'button[aria-label*="Stop generating" i]',
      ".result-streaming",
    ],
    claude: [
      '[data-is-streaming="true"]',
      'button[aria-label="Stop response" i]',
      'button[aria-label*="Stop response" i]',
    ],
    gemini: [
      'button[aria-label*="Stop response" i]',
      'button[aria-label*="Stop generating" i]',
      "model-response .pending",
    ],
  };

  const REPLY_SELECTORS = {
    chatgpt: ['[data-message-author-role="assistant"]'],
    claude: [".font-claude-response", ".font-claude-message", '[data-testid="assistant-message"]'],
    gemini: ["model-response message-content", "model-response .markdown", "model-response"],
  };

  const PROMPT_SELECTORS = {
    chatgpt: ['[data-message-author-role="user"]'],
    claude: ['[data-testid="user-message"]', ".font-user-message"],
    gemini: ["user-query .query-text", "user-query"],
  };

  // Settings (from the extension popup)
  let notifyWhenLooking = false;
  chrome.storage.sync.get({ notifyWhenLooking: false, enabled: true }, (s) => {
    notifyWhenLooking = s.notifyWhenLooking;
    if (!s.enabled) stop();
  });
  chrome.storage.onChanged.addListener((changes) => {
    if (changes.notifyWhenLooking) notifyWhenLooking = changes.notifyWhenLooking.newValue;
    if (changes.enabled) changes.enabled.newValue ? start() : stop();
  });

  const visible = (el) => {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };

  function isBusy() {
    for (const sel of BUSY_SELECTORS[site]) {
      for (const el of document.querySelectorAll(sel)) {
        if (sel.startsWith("[data-is-streaming") || sel.startsWith(".") || visible(el)) return true;
      }
    }
    // Generic fallback: a visible button that says "Stop …" near the composer.
    for (const b of document.querySelectorAll("button[aria-label], button[data-testid]")) {
      const label = `${b.getAttribute("aria-label") || ""} ${b.getAttribute("data-testid") || ""}`;
      if (/\bstop\b/i.test(label) && /(generat|respon|stream)/i.test(label) && visible(b)) return true;
    }
    return false;
  }

  function lastText(selectors) {
    for (const sel of selectors) {
      const all = document.querySelectorAll(sel);
      if (all.length) {
        const text = (all[all.length - 1].innerText || "").replace(/\s+/g, " ").trim();
        if (text) return text;
      }
    }
    return "";
  }

  function chatTitle() {
    const t = document.title
      .replace(/\s*[-|–]\s*(ChatGPT|Claude|Gemini).*$/i, "")
      .replace(/^(ChatGPT|Claude|Gemini)$/i, "")
      .trim();
    return t || `${NAMES[site]} chat`;
  }

  function chatId() {
    // /c/<id>, /chat/<id>, /app/<id> … fall back to the path.
    const m = location.pathname.match(/\/(?:c|chat|app|g\/[^/]+\/c)\/([\w-]+)/);
    return `web:${site}:${m ? m[1] : location.pathname}`;
  }

  const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

  function send(event) {
    try {
      chrome.runtime.sendMessage({ type: "cove-event", event });
    } catch (e) {
      // Extension was reloaded; this tab's script is orphaned until the page reloads.
    }
  }

  // State machine: idle → busy (after it's been busy ~0.6 s) → idle (after it's been quiet ~1.5 s).
  let busy = false;
  let busySince = 0;
  let quietSince = 0;
  let startedAt = 0;
  let currentId = null;
  let timer = null;

  function tick() {
    const now = Date.now();
    const nowBusy = isBusy();

    if (nowBusy) {
      quietSince = 0;
      if (!busy) {
        busySince = busySince || now;
        if (now - busySince > 600) {
          busy = true;
          startedAt = now;
          currentId = chatId();
          const prompt = clip(lastText(PROMPT_SELECTORS[site]), 90);
          send({
            id: currentId,
            kind: "running",
            source: site === "claude" ? "claude-web" : site,
            title: chatTitle(),
            body: prompt ? `“${prompt}”` : `${NAMES[site]} is answering…`,
          });
        }
      }
    } else {
      busySince = 0;
      if (busy) {
        quietSince = quietSince || now;
        if (now - quietSince > 1500) {
          busy = false;
          finish(now);
        }
      }
    }
  }

  function finish(now) {
    const id = currentId || chatId();
    const looking = document.visibilityState === "visible" && document.hasFocus();
    const seconds = Math.round((now - startedAt) / 1000);
    if (looking && !notifyWhenLooking) {
      // You watched it finish; just clear the live activity.
      send({ id, kind: "clear", title: chatTitle() });
      return;
    }
    const reply = clip(lastText(REPLY_SELECTORS[site]), 160);
    send({
      id,
      kind: "done",
      source: site === "claude" ? "claude-web" : site,
      title: chatTitle(),
      body: reply || `Answered in ${seconds}s`,
    });
  }

  function start() {
    if (timer) return;
    timer = setInterval(tick, 400);
  }
  function stop() {
    clearInterval(timer);
    timer = null;
  }

  start();

  // If you leave the page mid-answer, don't leave a spinner running in the notch.
  window.addEventListener("pagehide", () => {
    if (busy && currentId) send({ id: currentId, kind: "clear", title: chatTitle() });
  });
})();
