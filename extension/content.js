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

  let enabled = false;
  let notifyWhenLooking = false;
  let includePreviews = true;
  const visible = (el) => {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };

  function isBusy() {
    for (const sel of BUSY_SELECTORS[site]) {
      for (const el of document.querySelectorAll(sel)) {
        if (visible(el)) return true;
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

  // Stop controls identify real work; a quiet debounce prevents transient UI gaps from finishing it.
  let busy = false;
  let quietSince = 0;
  let startedAt = 0;
  let currentId = null;
  let currentTitle = "";
  let currentURL = "";
  let baselineReply = "";
  let idleReply = "";
  let lastPublishedAt = 0;
  let lastPublishedBody = "";
  let timer = null;
  let mutationTimer = null;
  let observer = null;

  function reset() {
    busy = false;
    quietSince = 0;
    currentId = null;
    lastPublishedAt = 0;
    lastPublishedBody = "";
  }

  function event(kind, body, phase, silent = false) {
    return { id: currentId, kind, source: site === "claude" ? "claude-web" : site,
      title: currentTitle, body, phase, url: currentURL, silent };
  }

  function publish(now, force = false) {
    const reply = lastText(REPLY_SELECTORS[site]);
    const writing = reply && reply !== baselineReply;
    const phase = writing ? "Writing reply" : "Generating response";
    const prompt = includePreviews ? clip(lastText(PROMPT_SELECTORS[site]), 90) : "";
    const body = writing
      ? (includePreviews ? clip(reply, 160) : `${reply.length} characters written`)
      : (prompt ? `“${prompt}”` : `${NAMES[site]} is working…`);
    const changed = `${phase}:${body}` !== lastPublishedBody;
    if (force || (changed && now - lastPublishedAt >= 2000) || now - lastPublishedAt >= 6000) {
      send(event("running", body, phase));
      lastPublishedAt = now;
      lastPublishedBody = `${phase}:${body}`;
    }
  }

  function tick() {
    if (!enabled) return;
    const now = Date.now();
    if (busy && chatId() !== currentId) {
      send(event("clear", "Chat changed"));
      reset();
      idleReply = lastText(REPLY_SELECTORS[site]);
    }
    if (isBusy()) {
      quietSince = 0;
      if (!busy) {
        busy = true;
        startedAt = now;
        currentId = chatId();
        currentTitle = chatTitle();
        currentURL = location.href;
        baselineReply = idleReply;
        publish(now, true);
      } else { publish(now); }
    } else if (busy) {
      quietSince = quietSince || now;
      if (now - quietSince >= 1500) {
        finish(now);
        reset();
        idleReply = lastText(REPLY_SELECTORS[site]);
      }
    } else { idleReply = lastText(REPLY_SELECTORS[site]); }
  }

  function finish(now) {
    const looking = document.visibilityState === "visible" && document.hasFocus();
    const seconds = Math.max(1, Math.round((now - startedAt) / 1000));
    const text = lastText(REPLY_SELECTORS[site]);
    const reply = includePreviews && text !== baselineReply ? clip(text, 160) : "";
    // A watched completion stays in the widget; only its interrupting banner is suppressed.
    send(event("done", reply || `Answered in ${seconds}s`, "Finished", looking && !notifyWhenLooking));
  }

  function start() {
    if (timer || !enabled) return;
    idleReply = lastText(REPLY_SELECTORS[site]);
    timer = setInterval(tick, 400);
    observer = new MutationObserver(() => {
      if (mutationTimer) return;
      mutationTimer = setTimeout(() => { mutationTimer = null; tick(); }, 80);
    });
    observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, characterData: true });
    tick();
  }
  function stop() {
    if (busy && currentId) send(event("clear", "Tracking paused"));
    clearInterval(timer);
    clearTimeout(mutationTimer);
    observer?.disconnect();
    timer = null;
    mutationTimer = null;
    observer = null;
    reset();
  }

  chrome.storage.sync.get({ notifyWhenLooking: false, enabled: true, includePreviews: true }, (settings) => {
    enabled = settings.enabled;
    notifyWhenLooking = settings.notifyWhenLooking;
    includePreviews = settings.includePreviews;
    if (enabled) start();
  });
  chrome.storage.onChanged.addListener((changes, area) => {
    if (area && area !== "sync") return;
    if (changes.notifyWhenLooking) notifyWhenLooking = changes.notifyWhenLooking.newValue;
    if (changes.includePreviews) includePreviews = changes.includePreviews.newValue;
    if (changes.enabled) {
      enabled = changes.enabled.newValue;
      enabled ? start() : stop();
    }
  });

  window.addEventListener("pagehide", stop);
  window.addEventListener("pageshow", () => { if (enabled) start(); });
})();
