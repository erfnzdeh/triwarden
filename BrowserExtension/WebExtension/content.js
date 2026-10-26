// Triwarden content script: a key button in login fields (fill after Touch ID in the app) and an
// offer to save what you typed when the form is submitted. Passwords are never stored by the extension.
(() => {
  if (window.__triwarden) return;
  window.__triwarden = true;
  const api = globalThis.browser ?? globalThis.chrome;
  const BRAND = "#0F74B3";
  const KEY_SVG = `<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true"><path fill="currentColor" d="M14.5 3a6.5 6.5 0 0 0-6.2 8.5L3 16.8V21h4.2v-2.1h2.1v-2.1h2.1l1.1-1.1A6.5 6.5 0 1 0 14.5 3Zm1.6 3.6a1.8 1.8 0 1 1 0 3.6 1.8 1.8 0 0 1 0-3.6Z"/></svg>`;

  const send = (message) =>
    new Promise((resolve) => {
      try {
        const maybe = api.runtime.sendMessage(message, resolve);
        if (maybe && typeof maybe.then === "function") maybe.then(resolve, (e) => resolve({ ok: false, error: String(e) }));
      } catch (e) {
        resolve({ ok: false, error: String(e) });
      }
    });

  const visible = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 20 && r.height > 10 && s.visibility !== "hidden" && s.display !== "none" && !el.disabled;
  };

  const textLike = (input) => {
    const type = (input.getAttribute("type") || "text").toLowerCase();
    return ["text", "email", "tel", ""].includes(type) || /username|email/.test(input.autocomplete || "");
  };

  /** The username field that belongs to a password field: the nearest text-like input before it. */
  function usernameFor(pw) {
    const scope = pw.form || document;
    const inputs = [...scope.querySelectorAll("input")].filter(visible);
    const at = inputs.indexOf(pw);
    for (let i = at - 1; i >= 0; i--) if (textLike(inputs[i])) return inputs[i];
    return scope.querySelector('input[autocomplete~="username"], input[type="email"]');
  }

  function setValue(input, value) {
    if (!input || value == null) return;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    input.focus();
    setter.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  // ---- Overlay (shadow DOM, so page styles can't touch it) ----
  const host = document.createElement("triwarden-overlay");
  host.style.cssText = "position:absolute;top:0;left:0;width:0;height:0;z-index:2147483647;";
  const root = host.attachShadow({ mode: "closed" });
  root.innerHTML = `<style>
    .key{position:absolute;width:22px;height:22px;border:0;border-radius:6px;padding:0;display:grid;place-items:center;
      color:${BRAND};background:transparent;cursor:pointer;opacity:.85}
    .key:hover{background:rgba(128,197,239,.25);opacity:1}
    .menu{position:absolute;min-width:240px;max-width:340px;padding:6px;border-radius:12px;font:13px -apple-system,system-ui,sans-serif;
      background:Canvas;color:CanvasText;box-shadow:0 10px 30px rgba(0,0,0,.18),0 0 0 .5px rgba(0,0,0,.15)}
    .row{display:flex;flex-direction:column;gap:1px;padding:7px 10px;border-radius:8px;cursor:pointer}
    .row:hover,.row:focus{background:#80C5EF;color:#0B2A40;outline:none}
    .row small{opacity:.7}
    .note{padding:8px 10px;opacity:.75}
    .head{padding:4px 10px 6px;font-weight:600;opacity:.6;font-size:11px;text-transform:uppercase;letter-spacing:.04em}
  </style>`;
  (document.body || document.documentElement).appendChild(host);

  const buttons = new Map(); // field -> button
  let menu = null;

  function place() {
    for (const [field, button] of buttons) {
      if (!field.isConnected || !visible(field)) { button.style.display = "none"; continue; }
      const r = field.getBoundingClientRect();
      button.style.display = "grid";
      button.style.left = `${r.right + scrollX - 28}px`;
      button.style.top = `${r.top + scrollY + (r.height - 22) / 2}px`;
    }
  }

  function closeMenu() { menu?.remove(); menu = null; }

  async function openMenu(field, pw) {
    closeMenu();
    const r = field.getBoundingClientRect();
    menu = document.createElement("div");
    menu.className = "menu";
    menu.style.left = `${r.left + scrollX}px`;
    menu.style.top = `${r.bottom + scrollY + 4}px`;
    menu.innerHTML = `<div class="head">Triwarden</div><div class="note">Looking for logins…</div>`;
    root.appendChild(menu);
    const reply = await send({ command: "match" });
    if (!menu) return;
    const note = menu.querySelector(".note");
    if (!reply?.ok) { note.textContent = reply?.error || "Triwarden isn't available."; return; }
    if (!reply.rows?.length) { note.textContent = "No logins for this site."; return; }
    note.remove();
    for (const row of reply.rows) {
      const el = document.createElement("div");
      el.className = "row";
      el.tabIndex = 0;
      el.innerHTML = "<span></span><small></small>";
      el.firstChild.textContent = row.name;
      el.lastChild.textContent = row.detail || "";
      const choose = async () => {
        closeMenu();
        const filled = await send({ command: "fill", query: row.id });
        if (!filled?.ok) return;
        const user = pw ? usernameFor(pw) : field;
        setValue(user, filled.username);
        setValue(pw || [...document.querySelectorAll('input[type="password"]')].find(visible), filled.password);
      };
      el.addEventListener("click", choose);
      el.addEventListener("keydown", (e) => e.key === "Enter" && choose());
      menu.appendChild(el);
    }
    menu.querySelector(".row")?.focus();
  }

  function decorate(field, pw) {
    if (!field || buttons.has(field)) return;
    const button = document.createElement("button");
    button.className = "key";
    button.type = "button";
    button.title = "Fill with Triwarden";
    button.setAttribute("aria-label", "Fill with Triwarden");
    button.innerHTML = KEY_SVG;
    button.addEventListener("mousedown", (e) => e.preventDefault());
    button.addEventListener("click", () => openMenu(field, pw));
    root.appendChild(button);
    buttons.set(field, button);
  }

  function scan() {
    for (const pw of document.querySelectorAll('input[type="password"]')) {
      if (!visible(pw) || /new-password/.test(pw.autocomplete || "")) continue;
      decorate(pw, pw);
      decorate(usernameFor(pw), pw);
    }
    place();
  }

  // ---- Offer to save on submit ----
  // Only a real login attempt counts: a form's submit, a click on its submit button (some pages handle that click
  // themselves and never fire submit), or, on pages with no form, Enter in the password field or a button that
  // reads like logging in. Other clicks (show password, menus, anything outside the form) never offer to save.
  // The app doesn't interrupt: it posts a notification and keeps the login in its bell until you answer.
  const LOGIN_LABEL = /\b(log ?in|log ?on|sign ?in|sign ?on|sign ?up|register|create account|continue|next|submit|save|update|change password)\b/i;
  let lastOffer = "";

  /** The password worth saving in `scope`: the new one on a change-password form, else the last one filled. */
  function submittedPassword(scope) {
    const filled = [...scope.querySelectorAll('input[type="password"]')].filter((p) => p.value);
    return filled.find((p) => /new-password/.test(p.autocomplete || "")) || filled[filled.length - 1];
  }

  function offerSave(scope) {
    const pw = submittedPassword(scope || document);
    if (!pw) return;
    const username = (usernameFor(pw)?.value || "").trim();
    const key = `${username}\u0000${pw.value}`;
    if (key === lastOffer) return;
    lastOffer = key;
    send({ command: "save", username, password: pw.value });
  }

  document.addEventListener("submit", (e) => offerSave(e.target), true);
  document.addEventListener("click", (e) => {
    const b = e.target.closest?.('button, input[type="submit"], input[type="button"], [role="button"]');
    if (!b || b.disabled) return;
    if (b.form) {
      // Inside a form only its submit button counts; type="button" ones (show password, etc.) never do.
      if (b.type === "submit") offerSave(b.form);
      return;
    }
    if (b.closest("form")) return; // a [role=button] inside a form: the form's own submit covers it
    const label = `${b.textContent || ""} ${b.value || ""} ${b.getAttribute("aria-label") || ""}`;
    if (LOGIN_LABEL.test(label)) offerSave(document);
  }, true);
  document.addEventListener("keydown", (e) => {
    const t = e.target;
    if (e.key === "Enter" && t instanceof HTMLInputElement && !t.form && (t.type === "password" || textLike(t))) offerSave(document);
  }, true);

  document.addEventListener("mousedown", (e) => { if (menu && !e.composedPath().includes(host)) closeMenu(); }, true);
  document.addEventListener("keydown", (e) => e.key === "Escape" && closeMenu(), true);
  addEventListener("scroll", () => { place(); }, { passive: true, capture: true });
  addEventListener("resize", place, { passive: true });
  new MutationObserver(() => { clearTimeout(scan.t); scan.t = setTimeout(scan, 250); })
    .observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["type", "style", "class"] });
  scan();
})();
