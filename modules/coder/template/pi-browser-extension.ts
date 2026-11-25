/**
 * pi-browser — drive a Chromium browser from the coding agent.
 *
 * WHY THIS EXISTS
 * ---------------
 * The workspace VM has no display, so there is nothing for a human to click. The
 * agent talks to Chromium over the Chrome DevTools Protocol (CDP) instead: a
 * websocket that exposes navigation, DOM inspection, synthetic input, JS
 * evaluation and screenshots. No browser-automation npm dependency is involved —
 * Node 22 ships a global `WebSocket` and `fetch`, and CDP is just JSON over a
 * socket, so this extension is a single self-contained file.
 *
 * TWO MODES
 * ---------
 * 1. Attach (the "watch me" mode): if `PI_BROWSER_CDP_URL` is set (the generated
 *    workspace flake points it at `http://127.0.0.1:9222`, where the
 *    `pi-browser-desktop` unit runs a *headed* Chromium on Xvfb, mirrored to the
 *    dashboard by x11vnc + noVNC), the extension attaches to that browser. The
 *    user watches and can take over the mouse in the Browser app; the agent
 *    drives the same tabs.
 * 2. Spawn (the default/fallback): with no reachable endpoint, the extension
 *    starts its own private headless Chromium with a persistent profile under
 *    `~/.pi/browser-profile`, so logins survive between sessions.
 *
 * TOOLS
 * -----
 * browser_open / browser_snapshot / browser_click / browser_type / browser_press
 * / browser_eval / browser_wait / browser_screenshot / browser_close.
 *
 * The interaction model is index-based (the same one Playwright MCP uses):
 * `browser_snapshot` stamps `data-pi-idx` on every visible interactive element
 * and returns them as a numbered list; `browser_click` / `browser_type` take
 * that index. Indices describe the DOM *at snapshot time* — after any page
 * change the agent must take a fresh snapshot, which is why every mutating tool
 * returns one.
 *
 * ENVIRONMENT
 * -----------
 *   PI_BROWSER_CDP_URL   http(s) base (e.g. http://127.0.0.1:9222) or ws:// URL
 *                        of a browser to attach to. Optional.
 *   PI_BROWSER_CHROMIUM  path to the chromium binary used in spawn mode.
 *   PI_BROWSER_PROFILE   user-data-dir for spawn mode. Default ~/.pi/browser-profile.
 *   PI_BROWSER_ARGS      extra command-line args (shell-like whitespace split).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";

const g = globalThis as any;
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

function errMsg(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function findOnPath(name: string): string | undefined {
  const exts = process.platform === "win32" ? [".exe", ".cmd", ""] : [""];
  for (const dir of (process.env.PATH ?? "").split(delimiter)) {
    if (!dir) continue;
    for (const ext of exts) {
      const candidate = join(dir, name + ext);
      if (existsSync(candidate)) return candidate;
    }
  }
  return undefined;
}

function chromiumBinary(): string {
  if (process.env.PI_BROWSER_CHROMIUM) return process.env.PI_BROWSER_CHROMIUM;
  for (const candidate of ["chromium", "chromium-browser", "google-chrome-stable", "google-chrome", "chrome"]) {
    const found = findOnPath(candidate);
    if (found) return found;
  }
  return "chromium";
}

// ---------------------------------------------------------------------------
// Minimal CDP client (flattened sessions, JSON over a single websocket)
// ---------------------------------------------------------------------------

type CdpEventHandler = (event: { method: string; params: any; sessionId?: string }) => void;

class Cdp {
  private nextId = 0;
  private pending = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();
  private handlers = new Set<CdpEventHandler>();
  closed = false;
  private ws: any;

  private constructor(ws: any) {
    this.ws = ws;
  }

  static async connect(url: string, timeoutMs = 10_000): Promise<Cdp> {
    const WebSocketImpl = g.WebSocket;
    if (typeof WebSocketImpl !== "function") {
      throw new Error("This Node.js runtime has no global WebSocket; Node 22 or newer is required.");
    }
    const ws = new WebSocketImpl(url);
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out connecting to ${url}`)), timeoutMs);
      ws.addEventListener("open", () => {
        clearTimeout(timer);
        resolve();
      });
      ws.addEventListener("error", (ev: any) => {
        clearTimeout(timer);
        reject(new Error(`Cannot connect to ${url}: ${ev?.message ?? "websocket error"}`));
      });
    });
    const cdp = new Cdp(ws);
    ws.addEventListener("message", (ev: any) => cdp.handleMessage(typeof ev.data === "string" ? ev.data : String(ev.data)));
    ws.addEventListener("close", () => {
      cdp.closed = true;
      for (const { reject } of cdp.pending.values()) reject(new Error("Browser connection closed"));
      cdp.pending.clear();
    });
    return cdp;
  }

  private handleMessage(raw: string): void {
    let msg: any;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }
    if (msg.id !== undefined) {
      const waiter = this.pending.get(msg.id);
      if (!waiter) return;
      this.pending.delete(msg.id);
      if (msg.error) {
        waiter.reject(new Error(msg.error.message ?? "CDP error"));
      } else {
        waiter.resolve(msg.result ?? {});
      }
      return;
    }
    if (msg.method) {
      for (const handler of this.handlers) {
        try {
          handler({ method: msg.method, params: msg.params ?? {}, sessionId: msg.sessionId });
        } catch {
          /* a broken listener must not kill the socket */
        }
      }
    }
  }

  on(handler: CdpEventHandler): void {
    this.handlers.add(handler);
  }

  send(method: string, params: any = {}, sessionId?: string, timeoutMs = 30_000): Promise<any> {
    if (this.closed) return Promise.reject(new Error("Browser connection closed"));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command ${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      try {
        this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err as Error);
      }
    });
  }

  close(): void {
    this.closed = true;
    try {
      this.ws.close();
    } catch {
      /* already gone */
    }
  }
}

// ---------------------------------------------------------------------------
// Page scripts (evaluated in the page; indices live in data-pi-idx)
// ---------------------------------------------------------------------------

const INTERACTIVE_SELECTOR =
  'a[href],button,input,select,textarea,summary,[role="button"],[role="link"],[role="checkbox"],' +
  '[role="tab"],[role="menuitem"],[role="switch"],[contenteditable="true"],[onclick]';

function snapshotScript(maxElements: number, maxText: number, maxScroll: number): string {
  return `(() => {
  for (const stale of document.querySelectorAll('[data-pi-idx]')) stale.removeAttribute('data-pi-idx');
  const els = [];
  let idx = 0;
  for (const el of document.querySelectorAll(${JSON.stringify(INTERACTIVE_SELECTOR)})) {
    const rect = el.getBoundingClientRect();
    const cs = getComputedStyle(el);
    if (rect.width <= 1 || rect.height <= 1) continue;
    if (cs.visibility === 'hidden' || cs.display === 'none' || cs.pointerEvents === 'none') continue;
    if (Number(cs.opacity) === 0) continue;
    const labelOf = el.closest('label');
    const candidates = [
      el.innerText,
      el.getAttribute('aria-label'),
      labelOf ? labelOf.innerText : '',
      el.getAttribute('placeholder'),
      el.getAttribute('title'),
      el.getAttribute('name'),
      el.value
    ];
    let raw = '';
    for (const candidate of candidates) {
      const trimmed = String(candidate || '').replace(/\\s+/g, ' ').trim();
      if (trimmed) {
        raw = trimmed;
        break;
      }
    }
    el.setAttribute('data-pi-idx', String(idx));
    const item = { i: idx, tag: el.tagName.toLowerCase(), label: raw.slice(0, 100) };
    if (el.type) item.type = el.type;
    if (el.disabled) item.disabled = true;
    if (el.type === 'checkbox' || el.type === 'radio') item.checked = !!el.checked;
    if (el.tagName === 'A' && el.getAttribute('href')) item.href = (el.getAttribute('href') || '').slice(0, 120);
    if (el.getAttribute && el.getAttribute('name')) item.name = el.getAttribute('name').slice(0, 40);
    if (el.value && el.type !== 'password') item.value = String(el.value).slice(0, 80);
    els.push(item);
    idx++;
    if (els.length >= ${maxElements}) break;
  }
  const bodyText = document.body && document.body.innerText ? document.body.innerText : '';
  const text = bodyText.replace(/\\n{3,}/g, '\\n\\n').trim().slice(0, ${maxText});
  return {
    url: location.href,
    title: document.title,
    elements: els,
    text,
    scroll: {
      y: Math.round(window.scrollY),
      height: Math.round(document.documentElement.scrollHeight),
      viewport: Math.round(window.innerHeight),
      canScrollMore: window.scrollY + window.innerHeight < document.documentElement.scrollHeight - 4,
      truncatedText: bodyText.length > ${maxText},
      truncatedScroll: Math.round(document.documentElement.scrollHeight) > ${maxScroll} * 1000
    },
    readyState: document.readyState
  };
})()`;
}

function clickScript(index: number): string {
  return `(() => {
  const el = document.querySelector('[data-pi-idx="${index}"]');
  if (!el) return { ok: false, reason: 'no element with index ${index} — call browser_snapshot for fresh indices' };
  el.scrollIntoView({ block: 'center', inline: 'center' });
  const r = el.getBoundingClientRect();
  return {
    ok: true,
    x: r.left + r.width / 2,
    y: r.top + r.height / 2,
    tag: el.tagName.toLowerCase(),
    label: (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().slice(0, 60)
  };
})()`;
}

function typeScript(index: number, text: string): string {
  return `(() => {
  const el = document.querySelector('[data-pi-idx="${index}"]');
  if (!el) return { ok: false, reason: 'no element with index ${index} — call browser_snapshot for fresh indices' };
  el.scrollIntoView({ block: 'center', inline: 'center' });
  el.focus();
  const value = ${JSON.stringify(text)};
  if (el.isContentEditable) {
    el.textContent = value;
  } else {
    const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
      : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype
      : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value') && Object.getOwnPropertyDescriptor(proto, 'value').set;
    if (setter) setter.call(el, value); else el.value = value;
  }
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return { ok: true, tag: el.tagName.toLowerCase() };
})()`;
}

function waitScript(text: string | undefined, selector: string | undefined): string {
  const parts: string[] = [];
  if (text) parts.push(`(document.body && document.body.innerText ? document.body.innerText : '').includes(${JSON.stringify(text)})`);
  if (selector) parts.push(`!!document.querySelector(${JSON.stringify(selector)})`);
  return `(() => (${parts.join(" && ") || "true"}))()`;
}

const KEY_CODES: Record<string, { key: string; code: string; vk: number; text?: string }> = {
  Enter: { key: "Enter", code: "Enter", vk: 13, text: "\r" },
  Tab: { key: "Tab", code: "Tab", vk: 9 },
  Escape: { key: "Escape", code: "Escape", vk: 27 },
  Backspace: { key: "Backspace", code: "Backspace", vk: 8 },
  Delete: { key: "Delete", code: "Delete", vk: 46 },
  ArrowUp: { key: "ArrowUp", code: "ArrowUp", vk: 38 },
  ArrowDown: { key: "ArrowDown", code: "ArrowDown", vk: 40 },
  ArrowLeft: { key: "ArrowLeft", code: "ArrowLeft", vk: 37 },
  ArrowRight: { key: "ArrowRight", code: "ArrowRight", vk: 39 },
  PageUp: { key: "PageUp", code: "PageUp", vk: 33 },
  PageDown: { key: "PageDown", code: "PageDown", vk: 34 },
  Home: { key: "Home", code: "Home", vk: 36 },
  End: { key: "End", code: "End", vk: 35 },
  Space: { key: " ", code: "Space", vk: 32, text: " " },
};

// ---------------------------------------------------------------------------
// Browser session
// ---------------------------------------------------------------------------

type Snapshot = {
  url: string;
  title: string;
  elements: Array<{ i: number; tag: string; label: string; type?: string; disabled?: boolean; checked?: boolean; href?: string; name?: string; value?: string }>;
  text: string;
  scroll: any;
  readyState: string;
};

function formatSnapshot(snap: Snapshot): string {
  const head = `URL: ${snap.url}\nTitle: ${snap.title || "(none)"}`;
  const elements = snap.elements.length
    ? snap.elements
        .map((el) => {
          const bits = [`[${el.i}]`, el.tag + (el.type ? `[${el.type}]` : "")];
          if (el.label) bits.push(JSON.stringify(el.label));
          if (el.checked !== undefined) bits.push(el.checked ? "(checked)" : "(unchecked)");
          if (el.disabled) bits.push("(disabled)");
          if (el.name) bits.push(`name=${el.name}`);
          if (el.value !== undefined) bits.push(`value=${JSON.stringify(el.value)}`);
          if (el.href) bits.push(`-> ${el.href}`);
          return bits.join(" ");
        })
        .join("\n")
    : "(no interactive elements found)";
  const scroll = `\n\nScroll: ${snap.scroll.y}/${Math.max(0, snap.scroll.height - snap.scroll.viewport)}px${
    snap.scroll.canScrollMore ? " (more content below — scroll with browser_press ArrowDown/PageDown or browser_eval)" : ""
  }`;
  return `${head}\n\nInteractive elements:\n${elements}${scroll}\n\nPage text:\n${snap.text || "(empty)"}`;
}

class Browser {
  private child?: ChildProcess;
  private cdp?: Cdp;
  private session?: string;
  private targetId?: string;
  private stderrTail: string[] = [];
  private profileDir = process.env.PI_BROWSER_PROFILE || join(homedir(), ".pi", "browser-profile");
  private dialogs = 0;

  private endpoint(): string | undefined {
    return process.env.PI_BROWSER_CDP_URL?.trim() || undefined;
  }

  async ensure(): Promise<void> {
    if (this.cdp && !this.cdp.closed && this.session) return;
    this.resetConnection();

    const external = this.endpoint();
    if (external) {
      try {
        await this.attach(external);
        return;
      } catch (err) {
        this.log(`attach to ${external} failed (${errMsg(err)}); falling back to a private headless browser`);
        this.resetConnection();
      }
    }
    await this.launch();
  }

  private log(line: string): void {
    this.stderrTail.push(line);
    if (this.stderrTail.length > 40) this.stderrTail.shift();
  }

  private resetConnection(): void {
    this.cdp?.close();
    this.cdp = undefined;
    this.session = undefined;
    this.targetId = undefined;
  }

  private async attach(endpoint: string): Promise<void> {
    let wsUrl = endpoint;
    if (/^https?:/i.test(endpoint)) {
      const base = endpoint.replace(/\/+$/, "");
      const res = await g.fetch(`${base}/json/version`, { signal: AbortSignal.timeout(5000) });
      if (!res.ok) throw new Error(`HTTP ${res.status} from ${base}/json/version`);
      const info = await res.json();
      if (!info.webSocketDebuggerUrl) throw new Error("no webSocketDebuggerUrl in /json/version");
      wsUrl = info.webSocketDebuggerUrl;
    }
    await this.openConnection(wsUrl);
    await this.pickPage();
  }

  private async openConnection(wsUrl: string): Promise<void> {
    const cdp = await Cdp.connect(wsUrl);
    this.cdp = cdp;
    cdp.on((event) => {
      // A JS alert()/confirm() blocks the page (and every CDP command touching
      // it) until it is answered. Accept whatever it asks: the alternative is a
      // hung tool call.
      if (event.method === "Page.javascriptDialogOpening" && event.sessionId === this.session) {
        this.dialogs += 1;
        cdp.send("Page.handleJavaScriptDialog", { accept: true }, event.sessionId).catch(() => {});
      }
    });
  }

  private async pickPage(): Promise<void> {
    const cdp = this.cdp!;
    const pages: any[] = [];
    for (const target of (await cdp.send("Target.getTargets")).targetInfos ?? []) {
      if (target.type === "page") pages.push(target);
    }
    const chosen = pages.find((p) => !/^(devtools|chrome-extension):/.test(p.url ?? "")) ?? pages[0];
    const targetId = chosen ? chosen.targetId : (await cdp.send("Target.createTarget", { url: "about:blank" })).targetId;
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    this.targetId = targetId;
    this.session = sessionId;
    await cdp.send("Page.enable", {}, sessionId);
    await cdp.send("Runtime.enable", {}, sessionId);
  }

  private async launch(): Promise<void> {
    const binary = chromiumBinary();
    mkdirSync(this.profileDir, { recursive: true });
    const portFile = join(this.profileDir, "DevToolsActivePort");
    try {
      rmSync(portFile);
    } catch {
      /* not there */
    }

    const args = [
      "--headless=new",
      "--no-sandbox",
      "--disable-gpu",
      "--disable-dev-shm-usage",
      "--disable-features=Translate,MediaRouter",
      "--password-store=basic",
      "--no-first-run",
      "--no-default-browser-check",
      "--window-size=1280,900",
      "--remote-debugging-port=0",
      `--user-data-dir=${this.profileDir}`,
      ...(process.env.PI_BROWSER_ARGS ? process.env.PI_BROWSER_ARGS.split(/\s+/).filter(Boolean) : []),
      "about:blank",
    ];

    try {
      const child = spawn(binary, args, { stdio: ["ignore", "ignore", "pipe"] });
      this.child = child;
      child.stderr?.setEncoding("utf8");
      child.stderr?.on("data", (chunk: string) => {
        for (const line of chunk.split("\n")) {
          // Chromium chatters about dbus/UPower in a container; only keep lines
          // that suggest a real failure.
          if (/error|fail|fatal|denied|crash/i.test(line) && !/dbus|DBus|UPower|GLES|Vulkan|gpu/i.test(line)) this.log(line.trim());
        }
      });
      child.on("exit", (code, sig) => this.log(`chromium exited (code ${code ?? "null"}, signal ${sig ?? "none"})`));
      (child as any).on("error", (err: Error) => this.log(`chromium spawn error: ${err.message}`));
    } catch (err) {
      throw new Error(`Cannot start Chromium (${binary}): ${errMsg(err)}. Install chromium or set PI_BROWSER_CHROMIUM.`);
    }

    const deadline = Date.now() + 25_000;
    let port: number | undefined;
    let wsPath: string | undefined;
    while (Date.now() < deadline) {
      if (existsSync(portFile)) {
        const [first, second] = readFileSync(portFile, "utf8").split("\n");
        const parsed = Number(first?.trim());
        if (parsed > 0 && second?.startsWith("/devtools/")) {
          port = parsed;
          wsPath = second.trim();
          break;
        }
      }
      if (this.child?.exitCode !== null && this.child?.exitCode !== undefined) break;
      await sleep(100);
    }
    if (!port || !wsPath) {
      const tail = this.stderrTail.slice(-8).join("\n") || "(no output)";
      throw new Error(`Chromium did not expose a CDP port within 25s (${binary}). Output:\n${tail}`);
    }

    await this.openConnection(`ws://127.0.0.1:${port}${wsPath}`);
    await this.pickPage();
  }

  private async cmd(method: string, params: any = {}, timeoutMs?: number): Promise<any> {
    await this.ensure();
    return this.cdp!.send(method, params, this.session!, timeoutMs);
  }

  async evaluate(expression: string): Promise<any> {
    const res = await this.cmd("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: true,
    });
    if (res.exceptionDetails) {
      const detail = res.exceptionDetails.exception?.description ?? res.exceptionDetails.text ?? "unknown error";
      throw new Error(`Page error: ${String(detail).split("\n")[0]}`);
    }
    return res.result?.value;
  }

  private async waitForLoad(timeoutMs = 20_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const state = await this.evaluate("document.readyState");
        if (state === "complete") {
          await sleep(120);
          return;
        }
      } catch {
        /* execution context may be swapped mid-navigation */
      }
      await sleep(100);
    }
  }

  async navigate(url: string): Promise<Snapshot> {
    let target = url.trim();
    if (!/^[a-z][a-z0-9+.-]*:/i.test(target)) target = `https://${target}`;
    await this.cmd("Page.bringToFront", {});
    const res = await this.cmd("Page.navigate", { url: target });
    if (res.errorText) throw new Error(`Navigation failed: ${res.errorText}`);
    await this.waitForLoad();
    return this.snapshot();
  }

  async snapshot(maxElements = 220, maxText = 5000): Promise<Snapshot> {
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        return await this.evaluate(snapshotScript(maxElements, maxText, 1000));
      } catch (err) {
        if (attempt === 2) throw err;
        await sleep(150);
      }
    }
    throw new Error("unreachable");
  }

  async click(index: number): Promise<string> {
    const point = await this.evaluate(clickScript(index));
    if (!point?.ok) return `Nothing clicked: ${point?.reason ?? "element not found"}`;
    const base = { x: Math.round(point.x), y: Math.round(point.y), button: "left", clickCount: 1 };
    await this.cmd("Input.dispatchMouseEvent", { type: "mouseMoved", x: base.x, y: base.y });
    await this.cmd("Input.dispatchMouseEvent", { type: "mousePressed", ...base });
    await this.cmd("Input.dispatchMouseEvent", { type: "mouseReleased", ...base });
    await sleep(350);
    await this.waitForLoad(10_000);
    return `Clicked [${index}] ${point.tag} ${JSON.stringify(point.label ?? "")}\n\n${formatSnapshot(await this.snapshot())}`;
  }

  async type(index: number, text: string, submit: boolean): Promise<string> {
    const res = await this.evaluate(typeScript(index, text));
    if (!res?.ok) return `Nothing typed: ${res?.reason ?? "element not found"}`;
    if (submit) {
      await this.press("Enter");
      await sleep(400);
      await this.waitForLoad(15_000);
    }
    return `Typed into [${index}] ${res.tag}${submit ? " and pressed Enter" : ""}\n\n${formatSnapshot(await this.snapshot())}`;
  }

  async press(key: string): Promise<string> {
    const named = KEY_CODES[key] ?? KEY_CODES[key.replace(/^Key/, "")];
    if (named) {
      const common = { windowsVirtualKeyCode: named.vk, nativeVirtualKeyCode: named.vk, key: named.key, code: named.code };
      await this.cmd("Input.dispatchKeyEvent", { type: named.text ? "keyDown" : "rawKeyDown", ...common, ...(named.text ? { text: named.text } : {}) });
      await this.cmd("Input.dispatchKeyEvent", { type: "keyUp", ...common });
      return `Pressed ${key}`;
    }
    if (key.length === 1) {
      await this.cmd("Input.dispatchKeyEvent", { type: "keyDown", key, text: key });
      await this.cmd("Input.dispatchKeyEvent", { type: "keyUp", key });
      return `Typed character ${JSON.stringify(key)}`;
    }
    throw new Error(`Unsupported key ${JSON.stringify(key)}. Use Enter, Tab, Escape, Backspace, Delete, ArrowUp/Down/Left/Right, PageUp/Down, Home, End, Space, or a single character.`);
  }

  async waitFor(text: string | undefined, selector: string | undefined, timeoutMs: number): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    const probe = waitScript(text, selector);
    while (Date.now() < deadline) {
      try {
        if (await this.evaluate(probe)) return `Condition met after ${timeoutMs - Math.max(0, deadline - Date.now())}ms\n\n${formatSnapshot(await this.snapshot())}`;
      } catch {
        /* navigating */
      }
      await sleep(250);
    }
    throw new Error(`Timed out after ${timeoutMs}ms waiting for ${text ? `text ${JSON.stringify(text)}` : ""}${text && selector ? " and " : ""}${selector ? `selector ${selector}` : ""}. Current state:\n${formatSnapshot(await this.snapshot())}`);
  }

  async screenshot(fullPage: boolean): Promise<{ data: string; mimeType: string }> {
    const height = fullPage ? Math.min(8000, Number(await this.evaluate("Math.round(document.documentElement.scrollHeight)")) || 900) : undefined;
    const res = await this.cmd(
      "Page.captureScreenshot",
      { format: "png", captureBeyondViewport: !!fullPage, ...(height ? { clip: { x: 0, y: 0, width: 1440, height, scale: 1 } } : {}) },
      60_000,
    );
    return { data: res.data, mimeType: "image/png" };
  }

  async close(): Promise<string> {
    const child = this.child;
    this.resetConnection();
    this.child = undefined;
    if (child && child.exitCode === null) {
      child.kill("SIGTERM");
      await sleep(300);
      if (child.exitCode === null) child.kill("SIGKILL");
      return "Closed the private headless browser.";
    }
    return "Detached from the shared browser (it keeps running).";
  }

  async dispose(): Promise<void> {
    const child = this.child;
    this.resetConnection();
    this.child = undefined;
    if (child && child.exitCode === null) {
      child.kill("SIGTERM");
      await sleep(200);
      if (child.exitCode === null) child.kill("SIGKILL");
    }
  }
}

// ---------------------------------------------------------------------------
// Extension wiring
// ---------------------------------------------------------------------------

export default function piBrowser(pi: ExtensionAPI) {
  const browser = new Browser();

  const guarded = async <T>(work: () => Promise<T>): Promise<T> => {
    try {
      return await work();
    } catch (err) {
      throw new Error(errMsg(err));
    }
  };

  pi.registerTool({
    name: "browser_open",
    label: "Open URL",
    description:
      "Open a URL in the Chromium browser and return the page's interactive elements and text. Indices from this snapshot are used by browser_click and browser_type.",
    promptSnippet: "Open a URL in the headless Chromium browser and snapshot the page",
    promptGuidelines: [
      "Use the browser_* tools to interact with web pages instead of curl when you need a JS-rendered page, a login flow, or to click/type anything.",
      "Always call browser_snapshot (or browser_open) before browser_click / browser_type: their indices come from the most recent snapshot and go stale as soon as the page changes.",
    ],
    parameters: Type.Object({
      url: Type.String({ description: "URL to open (https:// is assumed when no scheme is given)" }),
    }),
    async execute(_toolCallId, params) {
      return guarded(async () => {
        const snap = await browser.navigate(params.url);
        return { content: [{ type: "text", text: formatSnapshot(snap) }], details: { } };
      });
    },
  });

  pi.registerTool({
    name: "browser_snapshot",
    label: "Snapshot page",
    description:
      "Return the current page URL, title, numbered interactive elements (buttons, links, inputs) and visible text. Call this after any page change to get fresh indices.",
    promptSnippet: "Snapshot the current browser page (indices for browser_click/browser_type)",
    parameters: Type.Object({
      maxElements: Type.Optional(Type.Number({ description: "Maximum interactive elements to list (default 220)" })),
      maxText: Type.Optional(Type.Number({ description: "Maximum characters of page text (default 5000)" })),
    }),
    async execute(_toolCallId, params) {
      return guarded(async () => {
        const snap = await browser.snapshot(params.maxElements ?? 220, params.maxText ?? 5000);
        return { content: [{ type: "text", text: formatSnapshot(snap) }], details: {} };
      });
    },
  });

  pi.registerTool({
    name: "browser_click",
    label: "Click element",
    description:
      "Click the interactive element with the given index from the most recent snapshot, then return the updated page snapshot.",
    promptSnippet: "Click a numbered element from the last browser snapshot",
    parameters: Type.Object({
      index: Type.Number({ description: "Element index from the most recent browser_snapshot" }),
    }),
    async execute(_toolCallId, params) {
      return guarded(async () => {
        const text = await browser.click(params.index);
        return { content: [{ type: "text", text }], details: {} };
      });
    },
  });

  pi.registerTool({
    name: "browser_type",
    label: "Type into element",
    description:
      "Focus the element with the given index, replace its value with the given text (fires input/change events), optionally press Enter, then return the updated snapshot.",
    promptSnippet: "Type text into a numbered element from the last browser snapshot",
    parameters: Type.Object({
      index: Type.Number({ description: "Element index from the most recent browser_snapshot" }),
      text: Type.String({ description: "Text to type (replaces the current value)" }),
      submit: Type.Optional(Type.Boolean({ description: "Press Enter afterwards (default false)" })),
    }),
    async execute(_toolCallId, params) {
      return guarded(async () => {
        const text = await browser.type(params.index, params.text, params.submit ?? false);
        return { content: [{ type: "text", text }], details: {} };
      });
    },
  });

  pi.registerTool({
    name: "browser_press",
    label: "Press key",
    description: "Send a key press to the focused element (Enter, Tab, Escape, Backspace, arrows, PageUp/PageDown, Home, End, Space, or a single character).",
    promptSnippet: "Press a key in the browser (Enter, Tab, arrows, ...)",
    parameters: Type.Object({
      key: Type.String({ description: "Key name, e.g. Enter, Tab, Escape, ArrowDown, PageDown" }),
    }),
    async execute(_toolCallId, params) {
      return guarded(async () => {
        const text = await browser.press(params.key);
        return { content: [{ type: "text", text: `${text}\n\n${formatSnapshot(await browser.snapshot())}` }], details: {} };
      });
    },
  });

  pi.registerTool({
    name: "browser_eval",
    label: "Run JS in page",
    description:
      "Evaluate a JavaScript expression in the page (awaitable, result returned by value). Use for scrolling, reading data, filling complex widgets, or anything the click/type tools cannot express.",
    promptSnippet: "Evaluate JavaScript in the browser page",
    promptGuidelines: ["Use browser_eval for scrolling (window.scrollBy) or reading structured data that browser_snapshot's text view does not show."],
    parameters: Type.Object({
      expression: Type.String({ description: "JavaScript expression, e.g. 'window.scrollBy(0, 800)' or 'document.title'" }),
    }),
    async execute(_toolCallId, params) {
      return guarded(async () => {
        const value = await browser.evaluate(params.expression);
        const rendered = value === undefined ? "undefined" : typeof value === "string" ? value : JSON.stringify(value, null, 2);
        const clipped = rendered.length > 8000 ? `${rendered.slice(0, 8000)}\n… (truncated)` : rendered;
        return { content: [{ type: "text", text: clipped }], details: {} };
      });
    },
  });

  pi.registerTool({
    name: "browser_wait",
    label: "Wait for page",
    description: "Wait until the page contains the given text or selector (or just wait N ms), then return a fresh snapshot.",
    promptSnippet: "Wait for text/selector in the browser, then snapshot",
    parameters: Type.Object({
      text: Type.Optional(Type.String({ description: "Text that must appear in the page body" })),
      selector: Type.Optional(Type.String({ description: "CSS selector that must exist" })),
      timeoutMs: Type.Optional(Type.Number({ description: "Timeout in ms (default 10000)" })),
    }),
    async execute(_toolCallId, params) {
      return guarded(async () => {
        const text = await browser.waitFor(params.text, params.selector, params.timeoutMs ?? 10_000);
        return { content: [{ type: "text", text }], details: {} };
      });
    },
  });

  pi.registerTool({
    name: "browser_screenshot",
    label: "Screenshot page",
    description: "Capture the current page as a PNG image (useful for visual layout, canvases, or verifying what changed).",
    promptSnippet: "Take a PNG screenshot of the current browser page",
    parameters: Type.Object({
      fullPage: Type.Optional(Type.Boolean({ description: "Capture the full scrollable page instead of the viewport (default false)" })),
    }),
    async execute(_toolCallId, params) {
      return guarded(async () => {
        const shot = await browser.screenshot(params.fullPage ?? false);
        return {
          content: [
            { type: "text", text: "Screenshot of the current page:" },
            { type: "image", data: shot.data, mimeType: shot.mimeType },
          ],
          details: {},
        };
      });
    },
  });

  pi.registerTool({
    name: "browser_close",
    label: "Close browser",
    description: "Close the private headless browser started by this session, or detach from the shared workspace browser.",
    parameters: Type.Object({}),
    async execute() {
      return guarded(async () => ({ content: [{ type: "text", text: await browser.close() }], details: {} }));
    },
  });

  // The browser belongs to the session that opened it: kill a spawned Chromium
  // when the session goes away so it cannot outlive the conversation and hold
  // RAM in a workspace VM. A browser we merely attached to is left alone.
  pi.on("session_shutdown", async () => {
    await browser.dispose().catch(() => {});
  });
  process.once("exit", () => {
    void browser.dispose();
  });
}
