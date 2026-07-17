#!/usr/bin/env node
// ai-health.mjs — concurrent health probe + dynamic TUI for `cc/cx health`.
//
// Why this exists as a Node script (not shell): the old sh version probed via
// background `&` jobs, which printed zsh/bash job-control notifications ([N] PID
// / [N]+done) that interleaved with ANSI redraw and broke the table. Doing the
// concurrency + timed redraw inside one foreground Node process avoids shell job
// control entirely. Non-TTY (pipes/CI) prints a final table only.
//
// Usage: node ai-health.mjs <codex|claude> [--fresh]
import fs from 'fs';
import https from 'https';
import http from 'http';
import { URL } from 'url';

const tool = process.argv[2] || '';
const fresh = process.argv.includes('--fresh');
const HOME = process.env.HOME || process.env.HOMEPATH || '/root';
const expand = (x) => !x ? '' : String(x).replace(/^~(?=\/|$)/, HOME);
const registryPath = process.env.AI_REGISTRY_PATH || `${HOME}/.ai-env/profiles.json`;
const secretsPath = process.env.AI_SECRETS_PATH || `${HOME}/.ai-secrets/secrets.toml`;
const healthPath = process.env.AI_HEALTH_PATH || `${HOME}/.ai-env/health.json`;
const TTL = Number(process.env.AI_HEALTH_TTL || 300);
const TIMEOUT_MS = Number(process.env.AI_HEALTH_TIMEOUT_MS || 8000);
const DEGRADED_MS = Number(process.env.AI_HEALTH_DEGRADED_MS || 8000);
const isTty = process.stdout.isTTY && process.env.AI_HEALTH_LIVE !== '0';
const MAX_OUTPUT_WIDTH = 120;

// ---------- secrets.toml + config parsing (ported from _ai_probe_health) ----------
function parseSecrets(file) {
  const s = {};
  if (!fs.existsSync(file)) return s;
  let cur = null;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const sec = t.match(/^\[([^\]]+)\]\s*$/);
    if (sec) { cur = sec[1].trim(); s[cur] = s[cur] || {}; continue; }
    if (!cur) continue;
    const m = t.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);
    if (!m) continue;
    let v = m[2].trim();
    const dq = v.match(/^"((?:\\.|[^"])*)"/);
    if (dq) { try { v = JSON.parse(dq[0]); } catch { v = dq[1]; } }
    s[cur][m[1]] = v;
  }
  return s;
}
function tomlStr(file, key) {
  if (!fs.existsSync(file)) return '';
  const re = new RegExp('^\\s*' + key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*=\\s*"([^"]*)"');
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const m = line.match(re);
    if (m) return m[1];
  }
  return '';
}
function profileEnv(p, key) {
  return p && p.env && typeof p.env === 'object' && p.env[key] ? String(p.env[key]) : '';
}
function probeModelFor(toolName, p, sec, legacyEnv, profPath) {
  if (p.probe_model) return String(p.probe_model);
  if (toolName === 'claude') {
    return sec.ANTHROPIC_MODEL ||
      legacyEnv.ANTHROPIC_MODEL ||
      profileEnv(p, 'ANTHROPIC_MODEL') ||
      process.env.ANTHROPIC_MODEL ||
      sec.ANTHROPIC_DEFAULT_HAIKU_MODEL ||
      legacyEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL ||
      profileEnv(p, 'ANTHROPIC_DEFAULT_HAIKU_MODEL') ||
      process.env.ANTHROPIC_DEFAULT_HAIKU_MODEL ||
      'claude-3-5-haiku-20241022';
  }
  return tomlStr(profPath, 'model') ||
    tomlStr(expand(p.home || '~/.codex') + '/config.toml', 'model') ||
    'gpt-5.4-mini';
}

// ---------- probe one profile ----------
function buildPlan(p) {
  const mode = p.mode || 'api';
  if (mode !== 'api') return { early: { status: 'skip', latencyMs: 0, method: null, error: 'subscription mode (no remote probe)' } };
  const secrets = parseSecrets(secretsPath);
  const sid = p.secret_id || (tool + '.' + p.name);
  const sec = secrets[sid] || {};
  // legacy per-profile file (env)
  const legacyEnv = {};
  const legacy = expand(p.linux_secret || p.secret || '');
  if (legacy && fs.existsSync(legacy)) {
    for (const line of fs.readFileSync(legacy, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);
      if (m) legacyEnv[m[1]] = m[2].trim().replace(/^"|"$/g, '');
    }
  }
  let baseOrigin = '', headers = {}, probeModel = '';
  if (tool === 'claude') {
    probeModel = probeModelFor(tool, p, sec, legacyEnv, '');
    const b = sec.ANTHROPIC_BASE_URL || legacyEnv.ANTHROPIC_BASE_URL || p.base_url || '';
    baseOrigin = b.replace(/\/+$/, '');
    const at = sec.ANTHROPIC_AUTH_TOKEN || legacyEnv.ANTHROPIC_AUTH_TOKEN || process.env.ANTHROPIC_AUTH_TOKEN || '';
    const ak = sec.ANTHROPIC_API_KEY || legacyEnv.ANTHROPIC_API_KEY || process.env.ANTHROPIC_API_KEY || '';
    headers = { 'anthropic-version': '2023-06-01' };
    if (at) headers.Authorization = 'Bearer ' + at;
    if (ak) headers['x-api-key'] = ak;
    if (/\[1m\]/i.test(probeModel)) headers['anthropic-beta'] = 'context-1m-2025-08-07';
    headers['User-Agent'] = p.probe_ua || 'claude-cli/1.0.119 (external, cli)';
    if (!at && !ak) return { early: { status: 'down', latencyMs: 0, method: null, error: 'missing credentials' } };
  } else {
    const profPath = expand((p.home || '~/.codex') + '/' + (p.codex_profile || p.profile || String(p.name || '').replace(':', '-')) + '.config.toml');
    probeModel = probeModelFor(tool, p, sec, legacyEnv, profPath);
    let b = tomlStr(profPath, 'base_url');
    if (!b) b = tomlStr(expand(p.home || '~/.codex') + '/config.toml', 'openai_base_url');
    if (!b) b = 'built-in OpenAI/ChatGPT endpoint';
    baseOrigin = b.replace(/\/+$/, '');
    const k = sec.OPENAI_API_KEY || sec.CODEX_API_KEY || legacyEnv.OPENAI_API_KEY || '';
    headers = k ? { Authorization: 'Bearer ' + k } : {};
    headers['User-Agent'] = p.probe_ua || 'codex_cli_rs/0.40.0 (external, cli)';
    if (!k) return { early: { status: 'down', latencyMs: 0, method: null, error: 'missing credentials' } };
  }
  if (!baseOrigin || /^built-in/.test(baseOrigin)) return { early: { status: 'down', latencyMs: 0, method: null, error: 'missing base_url' } };
  const candidates = [];
  let effLabel = null, altLabel = null;
  if (tool === 'claude') {
    const apiBase = /\/v1$/.test(baseOrigin) ? baseOrigin.replace(/\/v1$/, '') : baseOrigin;
    candidates.push({ label: 'messages', url: apiBase + '/v1/messages', body: JSON.stringify({ model: probeModel, max_tokens: 1, messages: [{ role: 'user', content: '.' }] }), check: 'messages' });
  } else {
    const hasVer = /\/v\d+$/.test(baseOrigin);
    const apiBase = hasVer ? baseOrigin : baseOrigin + '/v1';
    candidates.push({ label: 'responses', url: apiBase + '/responses', body: JSON.stringify({ model: probeModel, input: '.', max_output_tokens: 1 }), check: 'responses' });
    candidates.push({ label: 'chat', url: apiBase + '/chat/completions', body: JSON.stringify({ model: probeModel, max_tokens: 1, messages: [{ role: 'user', content: '.' }] }), check: 'chat' });
    let wireApi = null;
    const profPath = expand((p.home || '~/.codex') + '/' + (p.codex_profile || p.profile || String(p.name || '').replace(':', '-')) + '.config.toml');
    if (fs.existsSync(profPath)) wireApi = tomlStr(profPath, 'wire_api');
    effLabel = (wireApi && /chat/.test(wireApi)) ? 'chat' : 'responses';
    altLabel = effLabel === 'chat' ? 'responses' : 'chat';
  }
  return { candidates, headers, effLabel, altLabel };
}
function fetchOne(c, headers) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const r = { ok: false, code: 0, latencyMs: 0, detail: null };
    let done = false;
    const fin = (x) => { if (!done) { done = true; Object.assign(r, x); r.latencyMs = Date.now() - t0; resolve(r); } };
    let obj;
    try { obj = new URL(c.url); } catch { fin({ detail: 'bad url' }); return; }
    const lib = obj.protocol === 'http:' ? http : https;
    const req = lib.request(obj, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(c.body) } }, (res) => {
      let d = '';
      res.on('data', (c2) => d += c2);
      res.on('end', () => {
        let valid = false;
        if (res.statusCode >= 200 && res.statusCode < 300) {
          try {
            const j = JSON.parse(d);
            if (c.check === 'messages') valid = (Array.isArray(j.content) && j.content.length > 0) || j.type === 'message';
            else if (c.check === 'responses') valid = (Array.isArray(j.output) && j.output.length > 0) || j.output_text || j.status === 'completed';
            else valid = Array.isArray(j.choices) && j.choices.length > 0;
          } catch {}
        }
        const compactBody = compactResponseBody(d).slice(0, 240);
        fin({ ok: valid, code: res.statusCode, detail: valid ? null : (res.statusCode >= 200 && res.statusCode < 300 ? '200 but no generated content' : ('HTTP ' + res.statusCode + (compactBody ? ' ' + compactBody : ''))) });
      });
    });
    req.on('timeout', () => { req.destroy(); fin({ detail: 'timeout' }); });
    req.on('error', (e) => fin({ detail: classifyErr(e.message) }));
    req.setTimeout(TIMEOUT_MS);
    req.write(c.body);
    req.end();
  });
}
function classifyErr(m) {
  const l = ('' + m).toLowerCase();
  if (/timeout|canceled|timed out/.test(l)) return 'timeout';
  if (/ssl|handshake|eproto|sslv3|certificate|trust/.test(l)) return 'TLS handshake failed';
  if (/econnrefused|connection refused/.test(l)) return 'connection refused';
  if (/enotfound|getaddrinfo|nodata|dns/.test(l)) return 'DNS failed';
  if (/econnreset|socket hang up|reset/.test(l)) return 'connection reset';
  return m;
}
function decodeUnicodeEscapes(value) {
  const decoded = String(value || '').replace(/\\u([0-9a-f]{4})/gi, (raw, hex) => {
    const code = Number.parseInt(hex, 16);
    return code < 0x20 || (code >= 0x7f && code < 0xa0) ? '?' : String.fromCharCode(code);
  });
  return decoded.replace(/[\u0000-\u001f\u007f-\u009f]/g, '?');
}
function compactResponseBody(body) {
  const raw = String(body || '');
  try {
    const j = JSON.parse(raw);
    const msg = j?.error?.message || j?.message || j?.error || j?.type || '';
    if (msg) return decodeUnicodeEscapes(msg).replace(/\s+/g, ' ').trim();
  } catch {}
  return decodeUnicodeEscapes(raw).replace(/\s+/g, ' ').trim();
}
function isModelUnsupported(detail) {
  const l = decodeUnicodeEscapes(detail).toLowerCase();
  return /no available providers|model_not_found|model not found|model does not exist|unknown model|unsupported model|model .*not supported|not support.*model|invalid model|model_not_supported|模型不存在|模型.*不存在|请检查模型代码/.test(l);
}
function compactHttpDetail(detail) {
  const text = decodeUnicodeEscapes(detail).replace(/\s+/g, ' ').trim();
  const http = text.match(/^(HTTP \d{3})(?:\s+(.+))?$/);
  if (!http) return text;
  const code = http[1];
  const body = http[2] || '';
  if (!body) return code;
  try {
    const j = JSON.parse(body);
    const msg = j?.error?.message || j?.message || j?.error || j?.type || '';
    if (msg) return code + ' ' + String(msg).replace(/\s+/g, ' ').trim();
  } catch {}
  const msg = body.match(/"message"\s*:\s*"([^"]+)"/) || body.match(/message=([^,;}]+)/);
  if (msg) return code + ' ' + msg[1].replace(/\s+/g, ' ').trim();
  return text;
}
function displayProbeErr(detail) {
  if (isModelUnsupported(detail)) return 'probe model unsupported; set probe_model';
  return compactHttpDetail(detail);
}
function displayNote(error) {
  const text = String(error || '').replace(/\s+/g, ' ').trim();
  if (!text) return '';
  const single = text.match(/^(POST\s+\/\S+\s+)(.+)$/);
  const dual = text.match(/^(POST\s+\/\S+\s+->\s+)(.+?)(;\s+\/\S+\s+->\s+)(.+)$/);
  if (dual) return dual[1] + displayProbeErr(dual[2]) + dual[3] + displayProbeErr(dual[4]);
  const wire = text.match(/^(POST\s+\/\S+\s+->\s+)(.+?)(;\s+but\s+\/\S+\s+works\s+->\s+.+)$/);
  if (wire) return wire[1] + displayProbeErr(wire[2]) + wire[3];
  if (single && !single[2].includes('; /')) return single[1] + displayProbeErr(single[2]);
  if (isModelUnsupported(text)) return displayProbeErr(text);
  return compactHttpDetail(text);
}
async function probeProfile(p) {
  const plan = buildPlan(p);
  if (plan.early) return plan.early;
  const results = {};
  await Promise.all(plan.candidates.map(async (c) => { results[c.label] = await fetchOne(c, plan.headers); }));
  if (tool === 'claude') {
    const m = results.messages;
    if (m.ok) return { status: m.latencyMs > DEGRADED_MS ? 'degraded' : 'healthy', latencyMs: m.latencyMs, method: 'generation', error: null };
    if (isModelUnsupported(m.detail)) return { status: 'degraded', latencyMs: m.latencyMs, method: 'none', error: 'POST /v1/messages ' + (m.detail || '') };
    if (m.code === 429 || (m.code >= 500 && m.code < 600)) return { status: 'degraded', latencyMs: m.latencyMs, method: 'none', error: 'POST /v1/messages ' + (m.detail || '') + ' (transient)' };
    return { status: 'down', latencyMs: m.latencyMs, method: 'none', error: 'POST /v1/messages ' + (m.detail || '') };
  }
  const eff = results[plan.effLabel], alt = results[plan.altLabel];
  if (eff.ok) return { status: eff.latencyMs > DEGRADED_MS ? 'degraded' : 'healthy', latencyMs: eff.latencyMs, method: 'generation:' + plan.effLabel, error: null };
  let note = 'POST /' + plan.effLabel + ' -> ' + (eff.detail || '');
  if (alt.ok) { note += '; but /' + plan.altLabel + ' works -> set wire_api = "' + plan.altLabel + '"'; return { status: 'degraded', latencyMs: eff.latencyMs, method: 'none', error: note }; }
  if (isModelUnsupported(eff.detail) || isModelUnsupported(alt.detail)) { note += '; /' + plan.altLabel + ' -> ' + (alt.detail || ''); return { status: 'degraded', latencyMs: eff.latencyMs, method: 'none', error: note }; }
  if (eff.code === 429 || (eff.code >= 500 && eff.code < 600)) { note += '; /' + plan.altLabel + ' -> ' + (alt.detail || '') + ' (transient)'; return { status: 'degraded', latencyMs: eff.latencyMs, method: 'none', error: note }; }
  note += '; /' + plan.altLabel + ' -> ' + (alt.detail || '');
  return { status: 'down', latencyMs: eff.latencyMs, method: 'none', error: note };
}

// ---------- rendering ----------
function cell(r) {
  if (!r) return '?';
  if (r.status === 'healthy') return '🟢' + r.latencyMs + 'ms';
  if (r.status === 'degraded') return '🟡' + (r.error && /HTTP \d{3}/.test(r.error) ? (r.error.match(/HTTP \d{3}/)[0].slice(-3)) : 'slow');
  if (r.status === 'down') return '🔴' + (r.error && /HTTP \d{3}/.test(r.error) ? (r.error.match(/HTTP \d{3}/)[0].slice(-3)) : 'err');
  if (r.status === 'skip') return '⏭';
  return '?';
}
const SPIN = ['-', '\\', '|', '/'];
function charWidth(cp) {
  if (cp === 0) return 0;
  if (cp < 32 || (cp >= 0x7f && cp < 0xa0)) return 0;
  if (cp >= 0x1100 && (
    cp <= 0x115f || cp === 0x2329 || cp === 0x232a ||
    (cp >= 0x2e80 && cp <= 0xa4cf) ||
    (cp >= 0xac00 && cp <= 0xd7a3) ||
    (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xfe10 && cp <= 0xfe19) ||
    (cp >= 0xfe30 && cp <= 0xfe6f) ||
    (cp >= 0xff00 && cp <= 0xff60) ||
    (cp >= 0xffe0 && cp <= 0xffe6) ||
    (cp >= 0x1f300 && cp <= 0x1faff)
  )) return 2;
  return 1;
}
function displayWidth(s) {
  let w = 0;
  for (const ch of String(s || '')) w += charWidth(ch.codePointAt(0));
  return w;
}
function padDisplay(s, n) {
  const text = String(s || '');
  return text + ' '.repeat(Math.max(0, n - displayWidth(text)));
}
function trunc(s, n) {
  const text = String(s || '');
  if (displayWidth(text) <= n) return text;
  const suffix = n > 3 ? '...' : '';
  const limit = Math.max(0, n - displayWidth(suffix));
  let out = '', w = 0;
  for (const ch of text) {
    const cw = charWidth(ch.codePointAt(0));
    if (w + cw > limit) break;
    out += ch;
    w += cw;
  }
  return out + suffix;
}
function outputWidth() {
  const configured = Number(process.env.AI_HEALTH_COLUMNS || 0);
  const detected = configured > 0 ? configured : (process.stdout.columns || MAX_OUTPUT_WIDTH);
  return Math.max(1, Math.min(MAX_OUTPUT_WIDTH, detected));
}
function boundedLine(text) {
  return trunc(text, outputWidth());
}
function buildTable(rows, saved, tick) {
  const cols = outputWidth();
  const w = { sel: 2, name: 14, health: 10, method: 12 };
  const noteW = Math.max(0, cols - (w.sel + w.name + w.health + w.method + 5));
  const lines = [];
  const fmt = (a, b, c, d, e) =>
    trunc(`${padDisplay(a, w.sel)} ${padDisplay(b, w.name)} ${padDisplay(c, w.health)} ${padDisplay(d, w.method)} ${trunc(e, noteW)}`, cols);
  lines.push(fmt('Sel', 'Name', 'Health', 'Method', 'Note'));
  lines.push(fmt('---', '----', '------', '------', '----'));
  for (const r of rows) {
    const sel = r.name === saved ? '*' : ' ';
    if (r.status === 'pending') {
      const sp = SPIN[tick % SPIN.length];
      lines.push(fmt(sel, r.name, '⏳', '-', 'checking ' + sp));
    } else {
      lines.push(fmt(sel, r.name, cell(r), r.method || '-', displayNote(r.error)));
    }
  }
  return lines.join('\n');
}
function readCache() { try { return JSON.parse(fs.readFileSync(healthPath, 'utf8')); } catch { return {}; } }
function writeCache(updates) {
  const all = readCache();
  const now = Math.floor(Date.now() / 1000);
  for (const [k, v] of Object.entries(updates)) all[k] = { status: v.status, latencyMs: v.latencyMs, method: v.method, error: v.error, probedAt: now };
  try { fs.mkdirSync(HOME + '/.ai-env', { recursive: true }); fs.writeFileSync(healthPath, JSON.stringify(all, null, 2) + '\n'); } catch {}
}

// ---------- main ----------
async function main() {
  const label = tool === 'codex' ? 'Codex' : 'Claude Code';
  const reg = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
  const all = (reg[tool] || []).filter((x) => x.enabled !== false);
  const saved = (readCache()._state?.[tool]) || (reg.defaults && reg.defaults[tool]) || (all[0] && all[0].name);
  // saved name: read from state.json
  let savedName = '';
  try { const st = JSON.parse(fs.readFileSync(HOME + '/.ai-env/state.json', 'utf8')); savedName = st[tool] || ''; } catch {}

  const cache = readCache();
  const rows = [];
  const todo = []; // {p, i}
  for (const p of all) {
    const n = p.name;
    if (!fresh) {
      const e = cache[tool + '.' + n];
      if (e && e.probedAt && (Math.floor(Date.now() / 1000) - e.probedAt) < TTL) {
        rows.push({ name: n, status: e.status, latencyMs: e.latencyMs, method: e.method, error: e.error });
        continue;
      }
    }
    rows.push({ name: n, status: 'pending' });
    todo.push({ p, i: rows.length - 1 });
  }

  process.stdout.write(boundedLine(label + ' profile health (' + registryPath + '):') + '\n');
  const updates = {};

  if (!isTty || todo.length === 0) {
    // Non-TTY: probe all (concurrent), then print final table.
    if (todo.length) {
      process.stdout.write(boundedLine('  probing ' + todo.length + ' profile(s) in parallel…') + '\n');
      await Promise.all(todo.map(async (t) => {
        const r = await probeProfile(t.p);
        rows[t.i] = { name: rows[t.i].name, ...r };
        if (r.status !== 'skip') updates[tool + '.' + rows[t.i].name] = r;
      }));
    }
    writeCache(updates);
    process.stdout.write(buildTable(rows, savedName, 0) + '\n');
    process.stdout.write(boundedLine('  (health ' + (fresh ? 're-probed (fresh, parallel)' : 'cached <=5min') + '; ' + tool + ' health --fresh re-probe, ' + tool + ' health-clear clears)') + '\n');
    return;
  }

  // TTY: dynamic in-place redraw via cursor-up-by-N. The earlier \x1b[s / \x1b[u
  // (save/restore cursor) isn't supported by all terminals and made the table
  // append/scroll downward. cursor-up \x1b[<N>A is universally supported; N is
  // exact because buildTable truncates columns to terminal width (no wrap).
  const HIDE = '\x1b[?25l', SHOW = '\x1b[?25h';
  const cleanup = () => { process.stdout.write(SHOW); };
  process.on('SIGINT', () => { cleanup(); process.exit(130); });
  process.on('SIGTERM', () => { cleanup(); process.exit(143); });
  process.on('exit', cleanup);
  let tick = 0, lastRender = 0, prevLines = 0;
  const render = (force) => {
    const now = Date.now();
    if (!force && now - lastRender < 100) return;
    lastRender = now;
    const table = buildTable(rows, savedName, tick);
    // move up the previously-printed table lines, clear to end of screen, reprint
    const up = prevLines > 0 ? '\x1b[' + prevLines + 'A\x1b[J' : '';
    process.stdout.write(up + table + '\n');
    prevLines = table.split('\n').length;
  };
  process.stdout.write(HIDE);
  render(true);
  const timer = setInterval(() => { tick++; render(); }, 100);
  await Promise.allSettled(todo.map(async (t) => {
    const r = await probeProfile(t.p);
    rows[t.i] = { name: rows[t.i].name, ...r };
    if (r.status !== 'skip') updates[tool + '.' + rows[t.i].name] = r;
    render(true);
  }));
  clearInterval(timer);
  writeCache(updates);
  render(true);
  process.stdout.write(SHOW + '\n' + boundedLine('  (health ' + (fresh ? 're-probed (fresh, parallel)' : 'cached <=5min') + '; ' + tool + ' health --fresh re-probe, ' + tool + ' health-clear clears)') + '\n');
}
main().catch((e) => { process.stderr.write(boundedLine('health error: ' + (e && e.message || e)) + '\n'); process.exit(1); });
