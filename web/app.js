// Pigeon sender. Everything is encrypted here, in the browser, to the Mac's
// public key before it is uploaded. The relay only ever sees ciphertext.
//
// Envelope (binary):  "WD1" | ephemeralPub(65, P-256 uncompressed) | iv(12) | AES-256-GCM(ciphertext||tag)
//   key  = HKDF-SHA256(ECDH(ephemeralPriv, macPub), salt = ephemeralPub||macPub, info = "pigeon v1")
//   aad  = "WD1" | ephemeralPub
// Plaintext: u32be(headerLen) | header JSON | body bytes
"use strict";

const MAGIC = new Uint8Array([0x57, 0x44, 0x31]); // "WD1"
const INFO = new TextEncoder().encode("pigeon v1");
const STORE = "pigeon.pairing.v1";
const NAME_STORE = "pigeon.devname";
let maxBytes = 100 * 1024 * 1024;

const $ = (id) => document.getElementById(id);
const enc = new TextEncoder();

function b64urlDecode(s) {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

function safeGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function safeSet(k, v) { try { localStorage.setItem(k, v); } catch {} }
function safeDel(k) { try { localStorage.removeItem(k); } catch {} }

// ---- pairing --------------------------------------------------------------
// The Mac shows a link like  https://host/#p=v1.<inbox>.<sendToken>.<pubkey>
// The fragment never leaves this device (browsers don't send it to servers).
function parsePairing(str) {
  const m = /^v1\.([A-Za-z0-9_-]{16,64})\.([A-Za-z0-9_-]{16,128})\.([A-Za-z0-9_-]{80,100})$/.exec(str || "");
  if (!m) return null;
  const pub = b64urlDecode(m[3]);
  if (pub.length !== 65 || pub[0] !== 0x04) return null;
  return { raw: str, inbox: m[1], sendToken: m[2], pub };
}

function loadPairing() {
  const hash = new URLSearchParams(location.hash.slice(1)).get("p");
  if (hash) {
    const p = parsePairing(hash);
    history.replaceState(null, "", location.pathname + location.search); // scrub secret from URL bar/history
    if (p) { safeSet(STORE, p.raw); return p; }
  }
  return parsePairing(safeGet(STORE));
}

async function fingerprint(pub) {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", pub));
  return Array.from(h.slice(0, 8), (b) => b.toString(16).padStart(2, "0")).join("").toUpperCase().match(/..../g).join("-");
}

// ---- crypto ---------------------------------------------------------------
async function seal(macPub, plaintext) {
  const recipient = await crypto.subtle.importKey("raw", macPub, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const eph = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const ephPub = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: recipient }, eph.privateKey, 256);
  const hk = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const key = await crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: concat(ephPub, macPub), info: INFO },
    hk, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const aad = concat(MAGIC, ephPub);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: aad }, key, plaintext));
  return concat(MAGIC, ephPub, iv, ct);
}

function frame(header, body) {
  const h = enc.encode(JSON.stringify(header));
  const len = new Uint8Array(4);
  new DataView(len.buffer).setUint32(0, h.length, false);
  return concat(len, h, body);
}

// ---- sending --------------------------------------------------------------
let pairing = null;

function deviceName() {
  const saved = safeGet(NAME_STORE);
  if (saved) return saved;
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return "iPhone";
  if (/iPad/.test(ua)) return "iPad";
  if (/Android/.test(ua)) return "Android";
  if (/Macintosh/.test(ua)) return navigator.maxTouchPoints > 1 ? "iPad" : "Mac";
  if (/Windows/.test(ua)) return "Windows PC";
  return "Browser";
}

function logRow(label) {
  const log = $("log");
  if (log.firstElementChild && log.firstElementChild.classList.contains("muted")) log.innerHTML = "";
  const li = document.createElement("li");
  const name = document.createElement("span");
  name.className = "name";
  name.textContent = label;
  const status = document.createElement("span");
  status.className = "muted";
  status.textContent = "Encrypting…";
  li.append(name, status);
  log.prepend(li);
  return (text, cls) => { status.textContent = text; status.className = cls || "muted"; };
}

function upload(blob, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", `api/inboxes/${pairing.inbox}/items`);
    xhr.setRequestHeader("X-Send-Token", pairing.sendToken);
    xhr.setRequestHeader("Content-Type", "application/octet-stream");
    xhr.upload.onprogress = (e) => e.lengthComputable && onProgress(e.loaded / e.total);
    xhr.onload = () => (xhr.status === 201 ? resolve() : reject(new Error(
      xhr.status === 404 ? "Pairing rejected. Re-pair from the Mac." :
      xhr.status === 413 ? "Too large" : `Server error ${xhr.status}`)));
    xhr.onerror = () => reject(new Error("Network error"));
    xhr.send(blob);
  });
}

async function send(header, body, label) {
  const set = logRow(label);
  try {
    if (body.length > maxBytes) throw new Error("Too large");
    header = { v: 1, ts: Date.now(), from: deviceName(), ...header };
    const sealed = await seal(pairing.pub, frame(header, body));
    set("Uploading…");
    await upload(new Blob([sealed]), (f) => set(`Uploading ${Math.round(f * 100)}%`));
    set("Sent ✓", "ok");
    return true;
  } catch (e) {
    set(e.message || "Failed", "err");
    return false;
  }
}

async function sendText(text) {
  if (!text) return;
  const preview = text.replace(/\s+/g, " ").trim();
  return send({ kind: "text" }, enc.encode(text), "“" + (preview.length > 40 ? preview.slice(0, 40) + "…" : preview) + "”");
}

async function sendFile(file) {
  const body = new Uint8Array(await file.arrayBuffer());
  const name = file.name || `pasted-${Date.now()}.${(file.type.split("/")[1] || "bin").replace(/[^a-z0-9]/gi, "")}`;
  return send({ kind: "file", name, type: file.type || "application/octet-stream", size: body.length }, body, name);
}

async function sendFiles(files) {
  for (const f of files) await sendFile(f);
}

// ---- UI wiring ------------------------------------------------------------
async function init() {
  pairing = loadPairing();
  if (!pairing) { $("unpaired").classList.remove("hidden"); return; }
  $("paired").classList.remove("hidden");
  const fp = await fingerprint(pairing.pub);
  $("fp").textContent = "🔒 " + fp.slice(0, 9);
  $("fpfull").textContent = fp;
  $("devname").value = deviceName();
  $("devname").addEventListener("change", (e) => {
    const v = e.target.value.trim();
    v ? safeSet(NAME_STORE, v) : safeDel(NAME_STORE);
  });

  fetch("api/health").then((r) => r.json()).then((h) => {
    if (h.maxMB) { maxBytes = h.maxMB * 1024 * 1024; $("maxmb").textContent = h.maxMB; }
  }).catch(() => {});

  $("sendText").addEventListener("click", async () => {
    const t = $("text");
    if (await sendText(t.value)) t.value = "";
  });
  $("text").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); $("sendText").click(); }
  });
  $("pasteSend").addEventListener("click", async () => {
    try {
      if (navigator.clipboard.read) {
        const items = await navigator.clipboard.read();
        for (const item of items) {
          const img = item.types.find((t) => t.startsWith("image/"));
          if (img) {
            const blob = await item.getType(img);
            await sendFile(new File([blob], `clipboard-${Date.now()}.${img.split("/")[1]}`, { type: img }));
            return;
          }
        }
      }
      const text = await navigator.clipboard.readText();
      if (text) await sendText(text);
      else logRow("Clipboard is empty")("—");
    } catch {
      logRow("Clipboard access was blocked. Paste into the box instead.")("—");
    }
  });

  // Pasting an image/file anywhere sends it straight away.
  document.addEventListener("paste", (e) => {
    const files = Array.from(e.clipboardData?.files || []);
    if (files.length) { e.preventDefault(); sendFiles(files); }
  });

  const drop = $("drop");
  $("file").addEventListener("change", (e) => { sendFiles(Array.from(e.target.files)); e.target.value = ""; });
  ["dragenter", "dragover"].forEach((ev) => document.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add("over"); }));
  ["dragleave", "drop"].forEach((ev) => document.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove("over"); }));
  document.addEventListener("drop", (e) => sendFiles(Array.from(e.dataTransfer.files)));

  $("forget").addEventListener("click", () => {
    if (confirm("Forget this pairing? You'll need to scan the QR code again.")) { safeDel(STORE); location.reload(); }
  });
}

// Opening a new pairing link in an already-open tab only changes the hash.
window.addEventListener("hashchange", () => location.reload());

init();
