# AI environment profile functions. Source this file from an interactive shell.

AI_HOME="${AI_ENV_HOME:-$HOME}"
AI_CONFIG_DIR="${AI_HOME}/.ai-env"
AI_REGISTRY_PATH="${AI_CONFIG_DIR}/profiles.json"
AI_STATE_PATH="${AI_CONFIG_DIR}/state.json"
AI_SECRETS_PATH="${AI_HOME}/.ai-secrets/secrets.toml"
LEGACY_AI_STATE_DIR="${AI_HOME}/.ai-state"
CLAUDE_ROUTER_BASE_URL="https://claude.example.com"

_ai_expand_path() {
  local input_path="${1:-}"
  case "$input_path" in
    "") return 0 ;;
    "~") printf '%s\n' "$AI_HOME" ;;
    "~/"*) printf '%s/%s\n' "$AI_HOME" "${input_path#\~/}" ;;
    *) printf '%s\n' "$input_path" ;;
  esac
}

_ai_require_node() {
  command -v node >/dev/null 2>&1 || {
    echo "ai-env needs node to read $AI_REGISTRY_PATH" >&2
    return 1
  }
}

_ai_profile_json() {
  local tool="$1" name="$2"
  _ai_require_node || return 1
  node -e '
const fs = require("fs");
const path = process.argv[1];
const tool = process.argv[2];
const query = String(process.argv[3] || "").toLowerCase();
const fallback = {
  defaults: { codex: "sub", claude: "sub" },
  codex: [
    { name: "sub", aliases: ["subscription", "chatgpt"], mode: "sub", home: "~/.codex", codex_profile: "sub" },
    { name: "api", aliases: ["router"], mode: "api", home: "~/.codex", codex_profile: "api", secret_id: "codex.api", linux_secret: "~/.ai-secrets/codex-api.env" }
  ],
  claude: [
    { name: "sub", aliases: ["subscription", "claude-sub"], mode: "sub" },
    { name: "api", aliases: ["router", "claude-api"], mode: "api", base_url: "https://claude.example.com", secret_id: "claude.api", linux_secret: "~/.ai-secrets/claude-api.env" }
  ]
};
let registry = fallback;
if (fs.existsSync(path)) registry = JSON.parse(fs.readFileSync(path, "utf8"));
for (const p of registry[tool] || []) {
  if (p.enabled === false) continue;
  const names = [p.name, ...(p.aliases || [])].filter(Boolean).map((x) => String(x).toLowerCase());
  if (names.includes(query)) {
    process.stdout.write(JSON.stringify(p));
    process.exit(0);
  }
}
process.exit(2);
' "$AI_REGISTRY_PATH" "$tool" "$name"
}

_ai_profile_value() {
  local profile_json="$1" key="$2" default_value="${3:-}"
  _ai_require_node || return 1
  node -e '
const p = JSON.parse(process.argv[1]);
const key = process.argv[2];
const fallback = process.argv[3] || "";
const value = Object.prototype.hasOwnProperty.call(p, key) ? p[key] : fallback;
if (Array.isArray(value)) process.stdout.write(value.join(","));
else if (value === undefined || value === null) process.stdout.write(fallback);
else process.stdout.write(String(value));
' "$profile_json" "$key" "$default_value"
}

_ai_default_profile() {
  local tool="$1"
  _ai_require_node || return 1
  node -e '
const fs = require("fs");
const path = process.argv[1];
const tool = process.argv[2];
let registry = { defaults: { codex: "sub", claude: "sub" } };
if (fs.existsSync(path)) registry = JSON.parse(fs.readFileSync(path, "utf8"));
process.stdout.write(String((registry.defaults && registry.defaults[tool]) || "sub"));
' "$AI_REGISTRY_PATH" "$tool"
}

_ai_legacy_saved_profile() {
  local tool="$1" file
  if [ "$tool" = "codex" ]; then
    file="${LEGACY_AI_STATE_DIR}/cx.profile"
  else
    file="${LEGACY_AI_STATE_DIR}/cc.profile"
  fi
  [ -f "$file" ] && head -n 1 "$file"
}

_ai_saved_profile() {
  local tool="$1" default_profile value
  default_profile="$(_ai_default_profile "$tool" 2>/dev/null || printf 'sub')"
  if _ai_require_node >/dev/null 2>&1 && [ -f "$AI_STATE_PATH" ]; then
    value="$(node -e '
const fs = require("fs");
const path = process.argv[1];
const tool = process.argv[2];
try {
  const state = JSON.parse(fs.readFileSync(path, "utf8"));
  process.stdout.write(String(state[tool] || ""));
} catch {}
' "$AI_STATE_PATH" "$tool")"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return
    fi
  fi
  value="$(_ai_legacy_saved_profile "$tool" || true)"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_profile"
  fi
}

_ai_save_profile() {
  local tool="$1" name="$2"
  mkdir -p "$AI_CONFIG_DIR"
  _ai_require_node || return 1
  node -e '
const fs = require("fs");
const path = process.argv[1];
const tool = process.argv[2];
const name = process.argv[3];
let state = {};
try {
  if (fs.existsSync(path)) state = JSON.parse(fs.readFileSync(path, "utf8"));
} catch {}
state[tool] = name;
state.updated_at = new Date().toISOString();
fs.writeFileSync(path, JSON.stringify(state, null, 2) + "\n");
' "$AI_STATE_PATH" "$tool" "$name"
}

_ai_name_slug() {
  local slug
  slug="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^[-_]+//; s/[-_]+$//')"
  if [ -z "$slug" ]; then
    echo "profile name '$1' does not contain any usable letters or numbers" >&2
    return 1
  fi
  printf '%s\n' "$slug"
}

_ai_validate_name() {
  case "$1" in
    ""|[^A-Za-z0-9]*|*[!A-Za-z0-9:_-]*)
      echo "profile name '$1' is not supported. Use letters, numbers, ':', '_' or '-'." >&2
      return 1
      ;;
  esac
}

_ai_registry_add_profile() {
  local tool="$1" profile_json="$2"
  mkdir -p "$AI_CONFIG_DIR"
  _ai_require_node || return 1
  node -e '
const fs = require("fs");
const path = process.argv[1];
const tool = process.argv[2];
const profile = JSON.parse(process.argv[3]);
const fallback = { schema: 1, defaults: { codex: "sub", claude: "sub" }, codex: [], claude: [] };
let registry = fallback;
try {
  if (fs.existsSync(path)) registry = JSON.parse(fs.readFileSync(path, "utf8"));
} catch {}
registry.schema = registry.schema || 1;
registry.defaults = registry.defaults || { codex: "sub", claude: "sub" };
registry.codex = Array.isArray(registry.codex) ? registry.codex : [];
registry.claude = Array.isArray(registry.claude) ? registry.claude : [];
const query = String(profile.name || "").toLowerCase();
for (const p of registry[tool] || []) {
  const names = [p.name, ...(p.aliases || [])].filter(Boolean).map((x) => String(x).toLowerCase());
  if (names.includes(query)) {
    console.error(`${tool} profile ${JSON.stringify(profile.name)} already exists. Remove it first, or choose another name.`);
    process.exit(4);
  }
}
registry[tool].push(profile);
fs.writeFileSync(path, JSON.stringify(registry, null, 2) + "\n");
' "$AI_REGISTRY_PATH" "$tool" "$profile_json"
}

_ai_registry_remove_profile() {
  local tool="$1" name="$2"
  _ai_require_node || return 1
  node -e '
const fs = require("fs");
const path = process.argv[1];
const tool = process.argv[2];
const query = String(process.argv[3] || "").toLowerCase();
if (!fs.existsSync(path)) {
  console.error(`${tool} profile ${JSON.stringify(process.argv[3])} does not exist.`);
  process.exit(4);
}
const registry = JSON.parse(fs.readFileSync(path, "utf8"));
const profiles = Array.isArray(registry[tool]) ? registry[tool] : [];
let removed = "";
registry[tool] = profiles.filter((p) => {
  const names = [p.name, ...(p.aliases || [])].filter(Boolean).map((x) => String(x).toLowerCase());
  if (names.includes(query)) {
    removed = String(p.name || process.argv[3]);
    return false;
  }
  return true;
});
if (!removed) {
  console.error(`${tool} profile ${JSON.stringify(process.argv[3])} does not exist.`);
  process.exit(4);
}
fs.writeFileSync(path, JSON.stringify(registry, null, 2) + "\n");
process.stdout.write(removed);
' "$AI_REGISTRY_PATH" "$tool" "$name"
}

_ai_parse_management_args() {
  _ai_require_node || return 1
  node -e '
const out = { positionals: [], options: {} };
const args = process.argv.slice(1);
for (let i = 0; i < args.length; i++) {
  const arg = String(args[i]);
  if (arg === "--env" && i + 1 < args.length) {
    (out.env = out.env || []).push(String(args[++i]));
    continue;
  }
  if (arg.startsWith("--")) {
    const key = arg.slice(2);
    if (!key) continue;
    if (i + 1 < args.length && !String(args[i + 1]).startsWith("--")) {
      out.options[key] = String(args[++i]);
    } else {
      out.options[key] = "true";
    }
  } else {
    out.positionals.push(arg);
  }
}
process.stdout.write(JSON.stringify(out));
' -- "$@"
}

_ai_mgmt_value() {
  local parsed="$1" key="$2" default_value="${3:-}"
  node -e '
const parsed = JSON.parse(process.argv[1]);
const key = process.argv[2];
const fallback = process.argv[3] || "";
process.stdout.write(parsed.options && parsed.options[key] ? String(parsed.options[key]) : fallback);
' "$parsed" "$key" "$default_value"
}

_ai_mgmt_positional() {
  local parsed="$1" index="$2"
  node -e '
const parsed = JSON.parse(process.argv[1]);
const index = Number(process.argv[2]);
process.stdout.write(parsed.positionals && parsed.positionals[index] ? String(parsed.positionals[index]) : "");
' "$parsed" "$index"
}

_ai_json_profile() {
  _ai_require_node || return 1
  node -e '
const profile = {};
for (let i = 1; i < process.argv.length; i += 2) {
  const key = process.argv[i];
  const raw = process.argv[i + 1] || "";
  if (key === "aliases") profile[key] = raw ? raw.split(",").filter(Boolean) : [];
  else if (key === "env") { if (raw) profile[key] = JSON.parse(raw); }
  else profile[key] = raw;
}
process.stdout.write(JSON.stringify(profile));
' "$@"
}

_ai_next_profile() {
  local tool="$1" saved
  saved="$(_ai_saved_profile "$tool")"
  _ai_require_node || return 1
  node -e '
const fs = require("fs");
const path = process.argv[1];
const tool = process.argv[2];
const saved = String(process.argv[3] || "").toLowerCase();
let registry = { defaults: { codex: "sub", claude: "sub" }, codex: [], claude: [] };
if (fs.existsSync(path)) registry = JSON.parse(fs.readFileSync(path, "utf8"));
const profiles = (registry[tool] || []).filter((p) => p.enabled !== false);
if (!profiles.length) {
  process.stdout.write("sub");
  process.exit(0);
}
const index = profiles.findIndex((p) => String(p.name || "").toLowerCase() === saved);
if (index >= 0) process.stdout.write(String(profiles[(index + 1) % profiles.length].name));
else process.stdout.write(String((registry.defaults && registry.defaults[tool]) || profiles[0].name || "sub"));
' "$AI_REGISTRY_PATH" "$tool" "$saved"
}

_ai_secret_path() {
  local profile_json="$1" secret_path
  secret_path="$(_ai_profile_value "$profile_json" linux_secret "")"
  [ -n "$secret_path" ] || secret_path="$(_ai_profile_value "$profile_json" secret "")"
  _ai_expand_path "$secret_path"
}

_ai_secret_id() {
  local tool="$1" profile_json="$2" secret_id name
  secret_id="$(_ai_profile_value "$profile_json" secret_id "")"
  if [ -n "$secret_id" ]; then
    printf '%s\n' "$secret_id"
  else
    name="$(_ai_profile_value "$profile_json" name "")"
    printf '%s.%s\n' "$tool" "$name"
  fi
}

_ai_toml_secret_exports() {
  local secret_id="$1"
  shift
  _ai_require_node || return 1
  [ -f "$AI_SECRETS_PATH" ] || return 1
  node -e '
const fs = require("fs");
const path = process.argv[1];
const target = process.argv[2];
const allowed = new Set(process.argv.slice(3));
const quote = (value) => {
  const text = String(value);
  return "'"'"'" + text.replace(/'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'";
};
const parseValue = (raw) => {
  const value = String(raw || "").trim();
  if (value.startsWith("\"")) {
    const match = value.match(/^"((?:\\.|[^"])*)"/);
    if (match) {
      try { return JSON.parse(match[0]); } catch { return match[1]; }
    }
  }
  if (value.startsWith("'"'"'")) {
    const match = value.match(/^'"'"'([^'"'"']*)'"'"'/);
    if (match) return match[1];
  }
  const bare = value.replace(/\s+#.*$/, "").trim();
  if (bare === "true" || bare === "false") return bare;
  return bare;
};
let current = "";
const values = {};
for (const line of fs.readFileSync(path, "utf8").split(/\r?\n/)) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) continue;
  const section = trimmed.match(/^\[([^\]]+)\]\s*$/);
  if (section) {
    current = section[1].trim();
    continue;
  }
  if (current !== target) continue;
  const item = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);
  if (!item || !allowed.has(item[1])) continue;
  const parsed = parseValue(item[2]);
  if (parsed !== "") values[item[1]] = parsed;
}
const entries = Object.entries(values);
if (!entries.length) process.exit(3);
for (const [key, value] of entries) console.log(`export ${key}=${quote(value)}`);
' "$AI_SECRETS_PATH" "$secret_id" "$@"
}

_ai_apply_toml_secret() {
  local secret_id="$1" exports
  shift
  exports="$(_ai_toml_secret_exports "$secret_id" "$@" 2>/dev/null)" || return 1
  [ -n "$exports" ] || return 1
  eval "$exports"
  AI_SECRET_SOURCE="${AI_SECRETS_PATH}#${secret_id}"
}

# Union of extra-env keys declared by any profile of the tool (for cleanup on switch).
_ai_all_env_keys() {
  local tool="$1"
  [ -f "$AI_REGISTRY_PATH" ] || return 0
  _ai_require_node || return 1
  node -e '
const fs = require("fs");
let registry;
try { registry = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch { process.exit(0); }
const keys = new Set();
for (const p of registry[process.argv[2]] || []) {
  if (p && p.env && typeof p.env === "object") for (const k of Object.keys(p.env)) keys.add(k);
}
for (const k of keys) console.log(k);
' "$AI_REGISTRY_PATH" "$tool"
}

# Emit `export KEY=value` lines for a profile's env map (shell-quoted).
_ai_profile_env_exports() {
  local profile_json="$1"
  _ai_require_node || return 1
  node -e '
const p = JSON.parse(process.argv[1]);
const quote = (value) => {
  const text = String(value);
  return "'"'"'" + text.replace(/'"'"'/g, "'"'"'\\'"'"''"'"'") + "'"'"'";
};
const env = (p && p.env && typeof p.env === "object") ? p.env : {};
for (const [k, v] of Object.entries(env)) console.log(`export ${k}=${quote(v)}`);
' "$profile_json"
}

# Build a JSON object from parsed --env KEY=VALUE pairs (empty string if none).
_ai_mgmt_env_json() {
  local parsed="$1"
  _ai_require_node || return 1
  node -e '
const parsed = JSON.parse(process.argv[1]);
const env = {};
for (const pair of parsed.env || []) {
  const s = String(pair);
  const idx = s.indexOf("=");
  if (idx < 1) continue;
  env[s.slice(0, idx)] = s.slice(idx + 1);
}
process.stdout.write(Object.keys(env).length ? JSON.stringify(env) : "");
' "$parsed"
}

_ai_env_keys_csv() {
  local env_json="$1"
  [ -n "$env_json" ] || return 0
  _ai_require_node || return 1
  node -e 'const e=JSON.parse(process.argv[1]||"{}");process.stdout.write(Object.keys(e).join(", "));' "$env_json"
}

_ai_interactive() {
  [ -z "${AI_ENV_NONINTERACTIVE:-}" ] || return 1
  [ -t 0 ] || return 1
  return 0
}

_ai_prompt() {
  local prompt="$1" default_value="${2:-}" answer label
  if [ -n "$default_value" ]; then label="$prompt [$default_value]: "; else label="$prompt: "; fi
  printf '%s' "$label" >&2
  IFS= read -r answer || answer=""
  [ -n "$answer" ] || answer="$default_value"
  printf '%s' "$answer"
}

_ai_prompt_secret() {
  local prompt="$1" answer
  printf '%s: ' "$prompt" >&2
  if [ -n "${BASH_VERSION:-}" ] || [ -n "${ZSH_VERSION:-}" ]; then
    read -rs answer || answer=""
  else
    read -r answer || answer=""
  fi
  printf '\n' >&2
  printf '%s' "$answer"
}

_ai_secret_section_exists() {
  local secret_id="$1"
  [ -f "$AI_SECRETS_PATH" ] || return 1
  awk -v want="[$secret_id]" '{ line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line); if (line==want) { found=1; exit } } END { exit found?0:1 }' "$AI_SECRETS_PATH"
}

_ai_append_secret() {
  local secret_id="$1" key="$2" value="$3" esc
  mkdir -p "$(dirname "$AI_SECRETS_PATH")"
  esc="$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  {
    [ -f "$AI_SECRETS_PATH" ] && printf '\n'
    printf '[%s]\n' "$secret_id"
    printf '%s = "%s"\n' "$key" "$esc"
  } >>"$AI_SECRETS_PATH"
}

# Returns a human-readable status; in interactive shells prompts for and writes a missing secret.
_ai_scaffold_secret() {
  local secret_id="$1" key="$2" interactive="$3" value
  if _ai_toml_secret_exports "$secret_id" "$key" >/dev/null 2>&1; then
    printf '%s [%s] %s (already set)' "$AI_SECRETS_PATH" "$secret_id" "$key"
    return 0
  fi
  if [ "$interactive" = "1" ] && ! _ai_secret_section_exists "$secret_id"; then
    value="$(_ai_prompt_secret "Enter $key for [$secret_id] (blank to skip)")"
    if [ -n "$value" ]; then
      _ai_append_secret "$secret_id" "$key" "$value"
      printf 'wrote %s [%s] %s' "$AI_SECRETS_PATH" "$secret_id" "$key"
      return 0
    fi
  fi
  printf 'add %s to %s [%s]' "$key" "$AI_SECRETS_PATH" "$secret_id"
}

_ai_secret_preview() {
  local value="${1:-}" len
  if [ -z "$value" ]; then
    printf '<unset>\n'
    return
  fi
  len=${#value}
  if [ "$len" -le 12 ]; then
    printf '%s...\n' "${value:0:4}"
  else
    printf '%s...%s\n' "${value:0:8}" "${value: -4}"
  fi
}

_ai_toml_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  sed -n \
    -e "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    -e "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([^#[:space:]]*\).*/\1/p" \
    "$file" | head -n 1
}

_codex_profile_name() {
  local profile_json="$1" value name
  value="$(_ai_profile_value "$profile_json" codex_profile "")"
  [ -n "$value" ] || value="$(_ai_profile_value "$profile_json" profile "")"
  if [ -z "$value" ]; then
    name="$(_ai_profile_value "$profile_json" name "")"
    value="${name/:/-}"
  fi
  printf '%s\n' "$value"
}

_codex_home() {
  local profile_json="$1"
  _ai_expand_path "$(_ai_profile_value "$profile_json" home "~/.codex")"
}

_codex_profile_path() {
  local profile_json="$1" home profile
  home="$(_codex_home "$profile_json")"
  profile="$(_codex_profile_name "$profile_json")"
  printf '%s/%s.config.toml\n' "$home" "$profile"
}

_ai_has_fresh_flag() {
  local a
  for a in "$@"; do
    case "$a" in
      --fresh|-f|--refresh|-r) return 0 ;;
    esac
  done
  return 1
}

_ai_probe_model_for() {
  local tool="$1" profile_json="$2"
  _ai_require_node || return 1
  node - "$tool" "$profile_json" "$AI_SECRETS_PATH" "$AI_HOME" <<'NODE'
const fs=require("fs");
const [tool,profileJson,secretsPath,homeArg]=process.argv.slice(2);
const P=JSON.parse(profileJson);
const home=homeArg||process.env.HOME||"";
if((P.mode||"sub")!=="api"){process.stdout.write("-");process.exit(0);}
const expand=(x)=>!x?"":String(x).replace(/^~(?=\/|$)/,home);
const tomlStr=(file,key)=>{if(!file||!fs.existsSync(file))return"";const re=new RegExp("^\\s*"+key.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")+"\\s*=\\s*\"([^\"]*)\"");for(const line of fs.readFileSync(file,"utf8").split(/\r?\n/)){const m=line.match(re);if(m)return m[1];}return"";};
const unquote=(raw)=>{let v=String(raw||"").trim();if(v.startsWith("\"")){const mm=v.match(/^"((?:\\.|[^"])*)"/);if(mm){try{return JSON.parse(mm[0]);}catch{return mm[1];}}}if(v.startsWith("'")){const end=v.indexOf("'",1);if(end>0)return v.slice(1,end);}return v.replace(/\s+#.*$/,"").trim();};
const parseSecrets=(file)=>{const s={};if(!file||!fs.existsSync(file))return s;let c="";for(const line of fs.readFileSync(file,"utf8").split(/\r?\n/)){const t=line.trim();if(!t||t.startsWith("#"))continue;const sec=t.match(/^\[([^\]]+)\]\s*$/);if(sec){c=sec[1].trim();s[c]=s[c]||{};continue;}if(!c)continue;const m=t.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);if(!m)continue;s[c][m[1]]=unquote(m[2]);}return s;};
const parseEnvFile=(file)=>{const e={};if(!file||!fs.existsSync(file))return e;for(const line of fs.readFileSync(file,"utf8").split(/\r?\n/)){const m=line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);if(!m)continue;e[m[1]]=unquote(m[2]);}return e;};
const profileEnv=(p,key)=>p&&p.env&&typeof p.env==="object"&&p.env[key]?String(p.env[key]):"";
const sec=(parseSecrets(secretsPath)[P.secret_id||(tool+"."+P.name)])||{};
const legacyEnv=parseEnvFile(expand(P.linux_secret||P.secret||""));
let model="";
if(P.probe_model)model=String(P.probe_model);
else if(tool==="claude")model=sec.ANTHROPIC_MODEL||legacyEnv.ANTHROPIC_MODEL||profileEnv(P,"ANTHROPIC_MODEL")||process.env.ANTHROPIC_MODEL||sec.ANTHROPIC_DEFAULT_HAIKU_MODEL||legacyEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL||profileEnv(P,"ANTHROPIC_DEFAULT_HAIKU_MODEL")||process.env.ANTHROPIC_DEFAULT_HAIKU_MODEL||"claude-3-5-haiku-20241022";
else{const profPath=expand((P.home||"~/.codex")+"/"+(P.codex_profile||P.profile||String(P.name||"").replace(":","-"))+".config.toml");model=tomlStr(profPath,"model")||tomlStr(expand(P.home||"~/.codex")+"/config.toml","model")||"gpt-5.4-mini";}
process.stdout.write(model);
NODE
}

_read_json_openai_key() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.OPENAI_API_KEY // empty' "$file"
  else
    node -e 'const fs=require("fs"); const p=process.argv[1]; const j=JSON.parse(fs.readFileSync(p,"utf8")); process.stdout.write(j.OPENAI_API_KEY || "");' "$file"
  fi
}

_codex_login_status() {
  command codex login status 2>&1 | tr '\n' ' '
}

_cx_doctor_summary() {
  local profile_json="$1" profile_file provider model base_url wire_api env_key requires_openai_auth provider_name json
  local -a args
  command -v codex >/dev/null 2>&1 || return
  command -v node >/dev/null 2>&1 || {
    echo "  Doctor: unavailable (node not found for JSON parsing)"
    return
  }

  profile_file="$(_codex_profile_path "$profile_json")"
  provider="$(_ai_toml_value "$profile_file" model_provider)"
  model="$(_ai_toml_value "$profile_file" model)"
  base_url="$(_ai_toml_value "$profile_file" base_url)"
  wire_api="$(_ai_toml_value "$profile_file" wire_api)"
  env_key="$(_ai_toml_value "$profile_file" env_key)"
  requires_openai_auth="$(_ai_toml_value "$profile_file" requires_openai_auth)"
  provider_name="$(_ai_toml_value "$profile_file" name)"

  args=(doctor --json)
  [ -n "$model" ] && args+=(-c "model=\"$model\"")
  [ -n "$provider" ] && args+=(-c "model_provider=\"$provider\"")

  if [ -n "$provider" ]; then
    case "$provider" in
      openai|ollama|lmstudio|amazon-bedrock)
        [ -z "${base_url}${wire_api}${env_key}${requires_openai_auth}${provider_name}" ] && provider=""
        ;;
    esac

    if [ -n "$provider" ]; then
      [ -n "$provider_name" ] || provider_name="$provider"
      [ -n "$wire_api" ] || wire_api="responses"
      args+=(-c "model_providers.$provider.name=\"$provider_name\"")
      [ -n "$base_url" ] && args+=(-c "model_providers.$provider.base_url=\"$base_url\"")
      [ -n "$wire_api" ] && args+=(-c "model_providers.$provider.wire_api=\"$wire_api\"")
      [ -n "$env_key" ] && args+=(-c "model_providers.$provider.env_key=\"$env_key\"")
      [ -n "$requires_openai_auth" ] && args+=(-c "model_providers.$provider.requires_openai_auth=$requires_openai_auth")
    fi
  fi

  json="$(command codex "${args[@]}" 2>/dev/null)" || {
    echo "  Doctor: unavailable"
    return
  }

  printf '%s' "$json" | node -e '
const fs = require("fs");
const j = JSON.parse(fs.readFileSync(0, "utf8"));
const check = (name) => j.checks && j.checks[name];
const detail = (c, key) => c && c.details ? c.details[key] : undefined;
const auth = check("auth.credentials");
const config = check("config.load");
const reach = check("network.provider_reachability");
const ws = check("network.websocket_reachability");
const sandbox = check("sandbox.helpers");
const threads = check("state.rollout_db_parity");
const updates = check("updates.status");
console.log(`  Doctor: ${j.overallStatus}, Codex ${j.codexVersion}`);
if (config) console.log(`  Runtime: model=${detail(config, "model")}; provider=${detail(config, "model provider")}; mcp=${detail(config, "mcp servers")}`);
if (auth) {
  console.log(`  Auth: ${auth.status} - ${auth.summary}`);
  if (detail(auth, "stored auth mode")) {
    console.log(`  Auth cache: ${detail(auth, "stored auth mode")}; api_key=${detail(auth, "stored API key")}; chatgpt_tokens=${detail(auth, "stored ChatGPT tokens")}`);
  }
}
if (reach) console.log(`  Network: ${reach.status} - ${reach.summary}`);
if (ws) console.log(`  WebSocket: ${ws.status} - ${ws.summary}`);
if (sandbox) console.log(`  Sandbox: approval=${detail(sandbox, "approval policy")}; fs=${detail(sandbox, "filesystem sandbox")}; net=${detail(sandbox, "network sandbox")}`);
if (threads) console.log(`  Threads: active=${detail(threads, "rollout DB active rows")}; archived=${detail(threads, "rollout DB archived rows")}; providers=${detail(threads, "rollout DB model providers")}`);
if (updates) console.log(`  Updates: ${detail(updates, "latest version status")}`);
'
}

_cc_external_status() {
  local json stats_path
  if command -v claude >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    json="$(command claude auth status --json 2>/dev/null || true)"
    if [ -n "$json" ]; then
      printf '%s' "$json" | node -e '
const fs = require("fs");
const a = JSON.parse(fs.readFileSync(0, "utf8"));
console.log(`  Auth status: loggedIn=${a.loggedIn}; method=${a.authMethod}; provider=${a.apiProvider}; source=${a.apiKeySource || "<none>"}`);
'
    else
      echo "  Auth status: unavailable"
    fi
  fi

  stats_path="$HOME/.claude/stats-cache.json"
  if [ -f "$stats_path" ] && command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const p = process.argv[1];
try {
  const s = JSON.parse(fs.readFileSync(p, "utf8"));
  console.log(`  Local usage cache: sessions=${s.totalSessions}; messages=${s.totalMessages}; lastComputed=${s.lastComputedDate}`);
} catch {}
' "$stats_path"
  fi
}

_set_codex_env() {
  local profile_json="$1" mode name secret secret_id legacy legacy_key
  mode="$(_ai_profile_value "$profile_json" mode sub)"
  name="$(_ai_profile_value "$profile_json" name "")"
  export CODEX_HOME="$(_codex_home "$profile_json")"
  export AI_CODEX_LABEL="$name"
  export AI_CODEX_PROFILE="$(_codex_profile_name "$profile_json")"
  mkdir -p "$CODEX_HOME"
  unset CODEX_API_KEY
  unset OPENAI_API_KEY
  local _ai_k
  for _ai_k in $(_ai_all_env_keys codex 2>/dev/null); do unset "$_ai_k" 2>/dev/null || true; done

  AI_SECRET_SOURCE="<none>"
  if [ "$mode" = "api" ]; then
    secret="$(_ai_secret_path "$profile_json")"
    secret_id="$(_ai_secret_id codex "$profile_json")"
    if _ai_apply_toml_secret "$secret_id" OPENAI_API_KEY CODEX_API_KEY; then
      :
    elif [ -f "$secret" ]; then
      # shellcheck source=/dev/null
      . "$secret"
      AI_SECRET_SOURCE="$secret"
    fi

    if [ -z "${OPENAI_API_KEY:-}" ] && [ -n "${CODEX_API_KEY:-}" ]; then
      export OPENAI_API_KEY="$CODEX_API_KEY"
    fi

    if [ -z "${OPENAI_API_KEY:-}" ] && [ "$name" = "api" ]; then
      for legacy in "$HOME/.codex.API/auth.json" "$HOME/.codex-api/auth.json"; do
        if [ -f "$legacy" ]; then
          legacy_key="$(_read_json_openai_key "$legacy")"
          if [ -n "$legacy_key" ]; then
            export OPENAI_API_KEY="$legacy_key"
            AI_SECRET_SOURCE="legacy .codex.API auth.json"
            break
          fi
        fi
      done
    fi

    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "cx $name needs OPENAI_API_KEY. Put it in ${AI_SECRETS_PATH} [${secret_id}] or $secret." >&2
      return 1
    fi
  fi

  eval "$(_ai_profile_env_exports "$profile_json" 2>/dev/null)"
}

_set_claude_env() {
  local profile_json="$1" mode name secret secret_id base_url
  mode="$(_ai_profile_value "$profile_json" mode sub)"
  name="$(_ai_profile_value "$profile_json" name "")"
  export AI_CLAUDE_LABEL="$name"
  unset ANTHROPIC_API_KEY
  unset ANTHROPIC_AUTH_TOKEN
  unset ANTHROPIC_BASE_URL
  unset ANTHROPIC_MODEL
  local _ai_k
  for _ai_k in $(_ai_all_env_keys claude 2>/dev/null); do unset "$_ai_k" 2>/dev/null || true; done

  AI_SECRET_SOURCE="<none>"
  if [ "$mode" = "api" ]; then
    secret="$(_ai_secret_path "$profile_json")"
    secret_id="$(_ai_secret_id claude "$profile_json")"
    if _ai_apply_toml_secret "$secret_id" ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL; then
      :
    elif [ -f "$secret" ]; then
      # shellcheck source=/dev/null
      . "$secret"
      AI_SECRET_SOURCE="$secret"
    fi

    base_url="$(_ai_profile_value "$profile_json" base_url "$CLAUDE_ROUTER_BASE_URL")"
    [ -n "${ANTHROPIC_BASE_URL:-}" ] || export ANTHROPIC_BASE_URL="$base_url"

    if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
      echo "cc $name needs ANTHROPIC_API_KEY or ANTHROPIC_AUTH_TOKEN in ${AI_SECRETS_PATH} [${secret_id}] or $secret." >&2
      return 1
    fi
  fi

  eval "$(_ai_profile_env_exports "$profile_json" 2>/dev/null)"
}

_cx_write_config_if_missing() {
  local profile_json="$1" base_url="${2:-}" model="${3:-}" env_key="${4:-OPENAI_API_KEY}" provider_name="${5:-}" mode name profile_file provider_id
  mode="$(_ai_profile_value "$profile_json" mode sub)"
  name="$(_ai_profile_value "$profile_json" name "")"
  profile_file="$(_codex_profile_path "$profile_json")"
  [ -f "$profile_file" ] && { printf '%s\n' "$profile_file"; return 0; }
  mkdir -p "$(dirname "$profile_file")"
  provider_id="api-router"
  [ -n "$provider_name" ] || provider_name="${name//:/ }"
  [ -n "$env_key" ] || env_key="OPENAI_API_KEY"

  if [ "$mode" = "api" ]; then
    [ -n "$base_url" ] || base_url="https://your-router.example/v1"
    {
      printf 'model_provider = "%s"\n' "$provider_id"
      [ -n "$model" ] && printf 'model = "%s"\n' "$model"
      printf 'disable_response_storage = true\n\n'
      printf '[model_providers.%s]\n' "$provider_id"
      printf 'name = "%s"\n' "$provider_name"
      printf 'base_url = "%s"\n' "$base_url"
      printf 'env_key = "%s"\n' "$env_key"
    } >"$profile_file"
  else
    {
      printf 'model_provider = "openai"\n'
      [ -n "$model" ] && printf 'model = "%s"\n' "$model"
    } >"$profile_file"
  fi

  printf '%s\n' "$profile_file"
}

_cx_add_api() {
  local parsed name slug home runtime_profile secret_id base_url model env_key provider_name env_json profile_json profile_file secret_state interactive
  parsed="$(_ai_parse_management_args "$@")" || return
  name="$(_ai_mgmt_positional "$parsed" 0)"
  [ -n "$name" ] || { echo "Usage: cx add-api <name> [--base-url URL] [--env-key NAME] [--provider-name NAME] [--model MODEL] [--home PATH] [--env KEY=VALUE ...]" >&2; return 1; }
  _ai_validate_name "$name" || return
  slug="$(_ai_name_slug "$name")" || return
  interactive=0; _ai_interactive && interactive=1
  home="$(_ai_mgmt_value "$parsed" home "~/.codex")"
  runtime_profile="$(_ai_mgmt_value "$parsed" profile "api-${slug//:/-}")"
  secret_id="$(_ai_mgmt_value "$parsed" secret-id "codex.$name")"
  model="$(_ai_mgmt_value "$parsed" model "")"
  env_json="$(_ai_mgmt_env_json "$parsed")"

  base_url="$(_ai_mgmt_value "$parsed" base-url "")"
  if [ -z "$base_url" ]; then
    if [ "$interactive" = "1" ]; then base_url="$(_ai_prompt "Codex base_url" "https://your-router.example/v1")"; else base_url="https://your-router.example/v1"; fi
  fi
  env_key="$(_ai_mgmt_value "$parsed" env-key "")"
  if [ -z "$env_key" ]; then
    if [ "$interactive" = "1" ]; then env_key="$(_ai_prompt "Codex env_key (secret variable name)" "OPENAI_API_KEY")"; else env_key="OPENAI_API_KEY"; fi
  fi
  provider_name="$(_ai_mgmt_value "$parsed" provider-name "")"
  if [ -z "$provider_name" ]; then
    if [ "$interactive" = "1" ]; then provider_name="$(_ai_prompt "Codex provider display name" "$name")"; else provider_name="$name"; fi
  fi

  profile_json="$(_ai_json_profile \
    name "$name" aliases "" mode api home "$home" codex_profile "$runtime_profile" \
    secret_id "$secret_id" linux_secret "~/.ai-secrets/codex-$slug.env" windows_secret "~/.ai-secrets/codex-$slug.ps1" \
    description "Codex API profile" env "$env_json")"
  _ai_registry_add_profile codex "$profile_json" || return
  profile_file="$(_cx_write_config_if_missing "$profile_json" "$base_url" "$model" "$env_key" "$provider_name")"
  secret_state="$(_ai_scaffold_secret "$secret_id" "$env_key" "$interactive")"
  echo "Added Codex API profile '$name'."
  echo "  Registry: $AI_REGISTRY_PATH"
  echo "  CODEX_HOME: $(_ai_expand_path "$home")"
  echo "  Config: $profile_file"
  echo "  Secret: $secret_state"
  [ -n "$env_json" ] && echo "  Env: $(_ai_env_keys_csv "$env_json")"
  return 0
}

_cx_add_sub() {
  local parsed name slug home runtime_profile model profile_json profile_file interactive
  parsed="$(_ai_parse_management_args "$@")" || return
  name="$(_ai_mgmt_positional "$parsed" 0)"
  [ -n "$name" ] || { echo "Usage: cx add-sub <name> [--home PATH] [--model MODEL]" >&2; return 1; }
  _ai_validate_name "$name" || return
  slug="$(_ai_name_slug "$name")" || return
  interactive=0; _ai_interactive && interactive=1
  home="$(_ai_mgmt_value "$parsed" home "")"
  if [ -z "$home" ]; then
    if [ "$interactive" = "1" ]; then home="$(_ai_prompt "Codex CODEX_HOME for this subscription" "~/.codex-$slug")"; else home="~/.codex-$slug"; fi
  fi
  runtime_profile="$(_ai_mgmt_value "$parsed" profile "sub")"
  model="$(_ai_mgmt_value "$parsed" model "")"
  profile_json="$(_ai_json_profile \
    name "$name" aliases "" mode sub home "$home" codex_profile "$runtime_profile" \
    description "Codex subscription profile")"
  _ai_registry_add_profile codex "$profile_json" || return
  profile_file="$(_cx_write_config_if_missing "$profile_json" "" "$model")"
  echo "Added Codex subscription profile '$name'."
  echo "  Registry: $AI_REGISTRY_PATH"
  echo "  CODEX_HOME: $(_ai_expand_path "$home")"
  echo "  Config: $profile_file"
  echo "  Login: CODEX_HOME=\"$(_ai_expand_path "$home")\" codex login"
}

_cx_remove_profile() {
  local parsed name removed existing_json profile_file delete_config
  parsed="$(_ai_parse_management_args "$@")" || return
  name="$(_ai_mgmt_positional "$parsed" 0)"
  [ -n "$name" ] || { echo "Usage: cx remove <name> [--delete-config]" >&2; return 1; }
  existing_json="$(_ai_profile_json codex "$name")" || { echo "codex profile '$name' does not exist." >&2; return 1; }
  profile_file="$(_codex_profile_path "$existing_json")"
  removed="$(_ai_registry_remove_profile codex "$name")" || return
  if [ "$(_ai_saved_profile codex)" = "$removed" ]; then
    _ai_save_profile codex "$(_ai_default_profile codex)" || return
  fi
  delete_config="$(_ai_mgmt_value "$parsed" delete-config "")"
  [ "$delete_config" = "true" ] && rm -f "$profile_file"
  echo "Removed Codex profile '$removed'."
  echo "  Registry: $AI_REGISTRY_PATH"
  if [ -f "$profile_file" ]; then
    echo "  Config: $profile_file"
  else
    echo "  Config: <removed or absent>"
  fi
}

_cc_add_api() {
  local parsed name slug secret_id base_url env_key env_json profile_json secret_state interactive
  parsed="$(_ai_parse_management_args "$@")" || return
  name="$(_ai_mgmt_positional "$parsed" 0)"
  [ -n "$name" ] || { echo "Usage: cc add-api <name> [--base-url URL] [--env-key NAME] [--env KEY=VALUE ...]" >&2; return 1; }
  _ai_validate_name "$name" || return
  slug="$(_ai_name_slug "$name")" || return
  interactive=0; _ai_interactive && interactive=1
  secret_id="$(_ai_mgmt_value "$parsed" secret-id "claude.$name")"
  env_json="$(_ai_mgmt_env_json "$parsed")"

  base_url="$(_ai_mgmt_value "$parsed" base-url "")"
  if [ -z "$base_url" ]; then
    if [ "$interactive" = "1" ]; then base_url="$(_ai_prompt "Claude base_url" "$CLAUDE_ROUTER_BASE_URL")"; else base_url="$CLAUDE_ROUTER_BASE_URL"; fi
  fi
  env_key="$(_ai_mgmt_value "$parsed" env-key "")"
  if [ -z "$env_key" ]; then
    if [ "$interactive" = "1" ]; then env_key="$(_ai_prompt "Claude secret variable (ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY)" "ANTHROPIC_AUTH_TOKEN")"; else env_key="ANTHROPIC_AUTH_TOKEN"; fi
  fi

  profile_json="$(_ai_json_profile \
    name "$name" aliases "" mode api base_url "$base_url" secret_id "$secret_id" \
    linux_secret "~/.ai-secrets/claude-$slug.env" windows_secret "~/.ai-secrets/claude-$slug.ps1" \
    description "Claude Code API profile" env "$env_json")"
  _ai_registry_add_profile claude "$profile_json" || return
  secret_state="$(_ai_scaffold_secret "$secret_id" "$env_key" "$interactive")"
  echo "Added Claude Code API profile '$name'."
  echo "  Registry: $AI_REGISTRY_PATH"
  echo "  Base URL: $base_url"
  echo "  Secret: $secret_state"
  [ -n "$env_json" ] && echo "  Env: $(_ai_env_keys_csv "$env_json")"
  return 0
}

_cc_add_sub() {
  local parsed name profile_json
  parsed="$(_ai_parse_management_args "$@")" || return
  name="$(_ai_mgmt_positional "$parsed" 0)"
  [ -n "$name" ] || { echo "Usage: cc add-sub <name>" >&2; return 1; }
  _ai_validate_name "$name" || return
  profile_json="$(_ai_json_profile name "$name" aliases "" mode sub description "Claude Code subscription profile")"
  _ai_registry_add_profile claude "$profile_json" || return
  echo "Added Claude Code subscription profile '$name'."
  echo "  Registry: $AI_REGISTRY_PATH"
  echo "  Login: claude /login"
}

_cc_remove_profile() {
  local parsed name removed
  parsed="$(_ai_parse_management_args "$@")" || return
  name="$(_ai_mgmt_positional "$parsed" 0)"
  [ -n "$name" ] || { echo "Usage: cc remove <name>" >&2; return 1; }
  removed="$(_ai_registry_remove_profile claude "$name")" || return
  if [ "$(_ai_saved_profile claude)" = "$removed" ]; then
    _ai_save_profile claude "$(_ai_default_profile claude)" || return
  fi
  echo "Removed Claude Code profile '$removed'."
  echo "  Registry: $AI_REGISTRY_PATH"
}

_ai_token_format() {
  node -e '
const value = Number(process.argv[1] || 0);
if (value >= 1000000) process.stdout.write(`${(value / 1000000).toFixed(2)}M`);
else if (value >= 1000) process.stdout.write(`${(value / 1000).toFixed(1)}K`);
else process.stdout.write(String(value));
' "$1"
}

_ai_token_bar() {
  node -e '
const value = Number(process.argv[1] || 0);
const total = Number(process.argv[2] || 0);
if (value <= 0 || total <= 0) process.exit(0);
const width = Math.max(1, Math.round((value / total) * 24));
process.stdout.write("#".repeat(width));
' "$1" "$2"
}

_cx_rollout_stats_json() {
  local codex_home="$1" days="$2"
  _ai_require_node || return 1
  node -e '
const fs = require("fs");
const path = require("path");
const root = process.argv[1];
const days = Number(process.argv[2] || 30);
const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;
const stats = { sessions: 0, samples: 0, input: 0, cachedInput: 0, output: 0, reasoningOutput: 0, total: 0 };
const sessions = path.join(root, "sessions");
const walk = (dir) => {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) out.push(full);
  }
  return out;
};
for (const file of walk(sessions)) {
  let st;
  try { st = fs.statSync(file); } catch { continue; }
  if (st.mtimeMs < cutoff) continue;
  let latest = null;
  let samples = 0;
  let text = "";
  try { text = fs.readFileSync(file, "utf8"); } catch { continue; }
  for (const line of text.split(/\r?\n/)) {
    if (!line.includes("\"token_count\"")) continue;
    try {
      const j = JSON.parse(line);
      if (j.type !== "event_msg" || !j.payload || j.payload.type !== "token_count") continue;
      const usage = j.payload.info && j.payload.info.total_token_usage;
      if (!usage) continue;
      latest = usage;
      samples += 1;
    } catch {}
  }
  if (!latest) continue;
  const input = Number(latest.input_tokens || 0);
  const cached = Number(latest.cached_input_tokens || latest.cache_read_input_tokens || 0);
  const output = Number(latest.output_tokens || 0);
  const reasoning = Number(latest.reasoning_output_tokens || 0);
  const total = Number(latest.total_tokens || input + output);
  stats.sessions += 1;
  stats.samples += samples;
  stats.input += input;
  stats.cachedInput += cached;
  stats.output += output;
  stats.reasoningOutput += reasoning;
  stats.total += total;
}
process.stdout.write(JSON.stringify(stats));
' "$codex_home" "$days"
}

_cx_stats() {
  local parsed days saved profile_json codex_home json sessions samples total input cached output reasoning
  parsed="$(_ai_parse_management_args "$@")" || return
  days="$(_ai_mgmt_value "$parsed" days 30)"
  case "$days" in
    ''|*[!0-9]*)
      echo "cx stats --days must be a positive integer." >&2
      return 1
      ;;
  esac
  [ "$days" -ge 1 ] || { echo "cx stats --days must be a positive integer." >&2; return 1; }
  saved="$(_ai_saved_profile codex)"
  profile_json="$(_ai_profile_json codex "${AI_CODEX_LABEL:-$saved}")" || profile_json="$(_ai_profile_json codex "$(_ai_default_profile codex)")" || return 1
  codex_home="${CODEX_HOME:-$(_codex_home "$profile_json")}"
  json="$(_cx_rollout_stats_json "$codex_home" "$days")" || return
  sessions="$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.sessions));' "$json")"
  samples="$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.samples));' "$json")"
  total="$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.total));' "$json")"
  input="$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.input));' "$json")"
  cached="$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.cachedInput));' "$json")"
  output="$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.output));' "$json")"
  reasoning="$(node -e 'const j=JSON.parse(process.argv[1]); process.stdout.write(String(j.reasoningOutput));' "$json")"
  echo "Codex local token stats:"
  echo "  CODEX_HOME: $codex_home"
  echo "  Window: last $days days"
  echo "  Sessions with usage: $sessions"
  echo "  Token samples: $samples"
  echo "  Total: $(_ai_token_format "$total") ($total)"
  printf '  %-9s %10s  %s\n' input "$(_ai_token_format "$input")" "$(_ai_token_bar "$input" "$total")"
  printf '  %-9s %10s  %s\n' cached "$(_ai_token_format "$cached")" "$(_ai_token_bar "$cached" "$total")"
  printf '  %-9s %10s  %s\n' output "$(_ai_token_format "$output")" "$(_ai_token_bar "$output" "$total")"
  printf '  %-9s %10s  %s\n' reasoning "$(_ai_token_format "$reasoning")" "$(_ai_token_bar "$reasoning" "$total")"
}

_cx_print_status() {
  local profile_json="$1" mode name profile_file base_url
  mode="$(_ai_profile_value "$profile_json" mode sub)"
  name="$(_ai_profile_value "$profile_json" name "")"
  profile_file="$(_codex_profile_path "$profile_json")"
  base_url="$(_ai_toml_value "$profile_file" base_url)"
  [ -n "$base_url" ] || base_url="built-in OpenAI/ChatGPT endpoint"
  echo "Codex state switched: $name"
  echo "  Run next: codex"
  echo "  Registry: $AI_REGISTRY_PATH"
  echo "  CODEX_HOME: $CODEX_HOME"
  echo "  Profile: $AI_CODEX_PROFILE ($profile_file)"
  echo "  Base URL: $base_url"
  echo "  Probe model: $(_ai_probe_model_for codex "$profile_json")"
  echo "  Cached login: $(_codex_login_status)"
  if [ "$mode" = "api" ]; then
    echo "  OPENAI_API_KEY: $(_ai_secret_preview "${OPENAI_API_KEY:-}")"
    echo "  Secret source: $AI_SECRET_SOURCE"
    echo "  API local check: profile file=$([ -f "$profile_file" ] && echo true || echo false); key=$([ -n "${OPENAI_API_KEY:-}" ] && echo true || echo false)"
  else
    echo "  OPENAI_API_KEY: <cleared>"
    echo "  Subscription quota: not exposed by Codex CLI"
  fi
  # Cached health line (instant — no network). codex doctor is deliberately
  # NOT run here: it does live network/websocket checks that stall the switch.
  # Use `cx doctor` for the full diagnostic on demand.
  _ai_health_status_line codex "$profile_json" 0
}

_cc_print_status() {
  local profile_json="$1" mode name
  mode="$(_ai_profile_value "$profile_json" mode sub)"
  name="$(_ai_profile_value "$profile_json" name "")"
  echo "Claude Code state switched: $name"
  echo "  Run next: claude"
  echo "  Registry: $AI_REGISTRY_PATH"
  echo "  Probe model: $(_ai_probe_model_for claude "$profile_json")"
  if [ "$mode" = "api" ]; then
    echo "  ANTHROPIC_BASE_URL: ${ANTHROPIC_BASE_URL:-<unset>}"
    echo "  ANTHROPIC_API_KEY: $(_ai_secret_preview "${ANTHROPIC_API_KEY:-}")"
    echo "  ANTHROPIC_AUTH_TOKEN: $(_ai_secret_preview "${ANTHROPIC_AUTH_TOKEN:-}")"
    echo "  Secret source: $AI_SECRET_SOURCE"
    echo "  API local check: auth=$([ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] && echo true || echo false); url=$([ -n "${ANTHROPIC_BASE_URL:-}" ] && echo true || echo false)"
  else
    echo "  Anthropic API env: <cleared>"
    echo "  Subscription status: local Claude login is used if present"
  fi
  _ai_health_status_line claude "$profile_json" 0
  _cc_external_status
}

_ai_list_profiles() {
  local tool="$1" output
  _ai_health_sync_cache "$tool"
  _ai_require_node || return 1
  output="$(node -e '
const fs = require("fs");
const path = process.argv[1];
const tool = process.argv[2];
const saved = process.argv[3];
const secretsPath = process.argv[4];
const healthPath = process.argv[5];
const ttl = Number(process.argv[6] || 300);
const home = process.env.HOME;
const now = Math.floor(Date.now() / 1000);
const exists = (p) => p && fs.existsSync(p);
const expand = (p) => !p ? "" : p.replace(/^~(?=\/|$)/, home);
const readToml = (file, key) => {
  if (!file || !fs.existsSync(file)) return "";
  const re = new RegExp("^\\s*" + key.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\$&") + "\\s*=\\s*\"([^\"]*)\"");
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const match = line.match(re);
    if (match) return match[1];
  }
  return "";
};
const parseValue = (raw) => {
  const value = String(raw || "").trim();
  if (value.startsWith("\"")) {
    const match = value.match(/^"((?:\\.|[^"])*)"/);
    if (match) {
      try { return JSON.parse(match[0]); } catch { return match[1]; }
    }
  }
  if (value.startsWith("'"'"'")) {
    const match = value.match(/^'"'"'([^'"'"']*)'"'"'/);
    if (match) return match[1];
  }
  return value.replace(/\s+#.*$/, "").trim();
};
const parseSecrets = (file) => {
  const sections = {};
  if (!fs.existsSync(file)) return sections;
  let current = "";
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const section = trimmed.match(/^\[([^\]]+)\]\s*$/);
    if (section) {
      current = section[1].trim();
      sections[current] = sections[current] || {};
      continue;
    }
    if (!current) continue;
    const item = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);
    if (item) sections[current][item[1]] = parseValue(item[2]);
  }
  return sections;
};
let registry = JSON.parse(fs.readFileSync(path, "utf8"));
const secrets = parseSecrets(secretsPath);
let health = {};
try { if (fs.existsSync(healthPath)) health = JSON.parse(fs.readFileSync(healthPath, "utf8")); } catch {}
const secretVars = tool === "codex" ? ["OPENAI_API_KEY", "CODEX_API_KEY"] : ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"];
const healthCell = (p) => {
  const e = health[`${tool}.${p.name || ""}`];
  if (!e || !e.probedAt || (now - Number(e.probedAt)) >= ttl) return "⏭";
  if (e.status === "healthy") return `🟢${e.latencyMs || 0}ms`;
  const code = String(e.error || "").match(/HTTP\s+(\d{3})/)?.[1];
  if (e.status === "degraded") return `🟡${code || "slow"}`;
  if (e.status === "down") return `🔴${code || "err"}`;
  if (e.status === "skip") return "⏭";
  return "?";
};
console.log(tool === "codex"
  ? ["Sel", "Name", "Mode", "Health", "Profile", "BaseUrl"].join("\t")
  : ["Sel", "Name", "Mode", "Health", "BaseUrl"].join("\t"));
for (const p of registry[tool] || []) {
  const mode = p.mode || "sub";
  const secretId = p.secret_id || `${tool}.${p.name || ""}`;
  const selected = String(p.name || "") === saved ? "*" : " ";
  const h = healthCell(p);
  if (tool === "codex") {
    const profile = p.codex_profile || p.profile || String(p.name || "").replace(":", "-");
    const runtime = `${expand(p.home || "~/.codex")}/${profile}.config.toml`;
    let baseUrl = readToml(runtime, "base_url") || readToml(`${expand(p.home || "~/.codex")}/config.toml`, "openai_base_url") || "built-in OpenAI/ChatGPT endpoint";
    console.log([selected, p.name || "", mode, h, profile, baseUrl].join("\t"));
  } else {
    let baseUrl = "local Claude subscription login";
    if (mode === "api") {
      baseUrl = (secrets[secretId] && secrets[secretId].ANTHROPIC_BASE_URL) || p.base_url || "https://claude.example.com";
    }
    console.log([selected, p.name || "", mode, h, baseUrl].join("\t"));
  }
}
' "$AI_REGISTRY_PATH" "$tool" "$(_ai_saved_profile "$tool")" "$AI_SECRETS_PATH" "$AI_HEALTH_PATH" "$AI_HEALTH_TTL")" || return 1

  if command -v column >/dev/null 2>&1; then
    printf '%s\n' "$output" | column -t -s "$(printf '\t')"
  else
    printf '%s\n' "$output"
  fi
  if [ "$tool" = "codex" ]; then
    echo "  (Health = cached snapshot, ⏭=stale/unprobed; run 'cx health' to refresh)"
  else
    echo "  (Health = cached snapshot, ⏭=stale/unprobed; run 'cc health' to refresh)"
  fi
}

cx() {
  local arg="${1:-}" profile_json name
  case "$arg" in
    help|-h|--help)
      cat <<'EOF'
cx - switch Codex state for this shell

Usage:
  cx                 Auto-select a cached healthy Codex profile (default fallback)
  cx sub             Use a named subscription profile
  cx sub:work        Use another subscription profile, if registered
  cx api             Use the default API profile
  cx api:docker      Use a named API profile
  cx list            List registry profiles and cached health
  cx status          Print current state; --fresh/--refresh re-probes selected profile
  cx stats           Summarize local rollout token usage
  cx add-api NAME    Register a Codex API profile that shares ~/.codex by default
                     Options: --base-url URL --env-key NAME --provider-name NAME
                              --model MODEL --home PATH --env KEY=VALUE
                     Prompts for missing base-url/env-key and the secret in a terminal.
  cx add-sub NAME    Register an isolated Codex subscription CODEX_HOME
  cx remove NAME     Remove a Codex profile registration
  cx probe-model NAME [MODEL]  Set/clear health-probe model override
  cx default [NAME]  Show/set the default (primary) profile
  cx edit            Open the profile registry (profiles.json) in EDITOR
  cx health          Probe & report profile health table; --fresh/--refresh re-probes
  cx doctor          Run codex doctor full diagnostic (slow, on-demand)
  cx health-clear    Clear the health probe cache
  cx next            Cycle to the next enabled profile
  cx help            Show this help

Config:
  Registry: ~/.ai-env/profiles.json
  State:    ~/.ai-env/state.json
  Secrets:  ~/.ai-secrets/secrets.toml

After switching, run Codex separately: codex
Add commands only write profile metadata and Codex config. Put real tokens in secrets.toml.
Without probe_model, Codex probes use runtime/global config.toml model, then a cheap fallback.
Legacy ~/.ai-secrets/*.env files are still accepted as a fallback.
EOF
      return
      ;;
    list)
      echo "Codex profiles ($AI_REGISTRY_PATH):"
      _ai_list_profiles codex
      return
      ;;
    status)
      _hr=0; _ai_has_fresh_flag "$@" && _hr=1
      echo "Codex state:"
      echo "  Registry: $AI_REGISTRY_PATH"
      echo "  State: $AI_STATE_PATH"
      echo "  Saved: $(_ai_saved_profile codex)"
      echo "  Process label: ${AI_CODEX_LABEL:-<unset>}"
      echo "  Process profile: ${AI_CODEX_PROFILE:-<unset>}"
      echo "  CODEX_HOME: ${CODEX_HOME:-$HOME/.codex}"
      echo "  OPENAI_API_KEY: $(_ai_secret_preview "${OPENAI_API_KEY:-}")"
      echo "  Cached login: $(_codex_login_status)"
      profile_json="$(_ai_profile_json codex "${AI_CODEX_LABEL:-$(_ai_saved_profile codex)}")" && {
        echo "  Probe model: $(_ai_probe_model_for codex "$profile_json")"
        _ai_health_status_line codex "$profile_json" "$_hr"
      }
      return
      ;;
    edit)
      _ai_registry_edit
      return
      ;;
    stats)
      shift
      _cx_stats "$@"
      return
      ;;
    add-api)
      shift
      _cx_add_api "$@"
      return
      ;;
    add-sub)
      shift
      _cx_add_sub "$@"
      return
      ;;
    remove)
      shift
      _cx_remove_profile "$@"
      return
      ;;
    health)
      shift
      _hf=0; _ai_has_fresh_flag "$@" && _hf=1
      _ai_health_show codex "$_hf"
      return
      ;;
    doctor)
      profile_json="$(_ai_profile_json codex "${AI_CODEX_LABEL:-$(_ai_saved_profile codex)}")" && _cx_doctor_summary "$profile_json"
      return
      ;;
    default)
      shift; _ai_set_default codex "$@"; return
      ;;
    probe-model)
      shift; _ai_set_probe_model codex "$@"; return
      ;;
    health-clear)
      _ai_health_clear; echo "health cache cleared"; return
      ;;
    next)
      arg="$(_ai_next_profile codex)"
      ;;
  esac

  if [ -n "$arg" ]; then
    profile_json="$(_ai_profile_json codex "$arg")" || { echo "Unknown cx profile '$arg'. Add it to $AI_REGISTRY_PATH or run 'cx help'." >&2; return 1; }
  else
    profile_json="$(_ai_profile_json codex "$(_ai_healthy_profile codex)")" || return 1
  fi
  name="$(_ai_profile_value "$profile_json" name "")"
  _ai_save_profile codex "$name" || return
  _set_codex_env "$profile_json" || return
  _cx_print_status "$profile_json"
}

cc() {
  local arg="${1:-}" profile_json name
  case "$arg" in
    help|-h|--help)
      cat <<'EOF'
cc - switch Claude Code state for this shell

Usage:
  cc                 Auto-select a cached healthy Claude Code profile (default fallback)
  cc sub             Clear Anthropic API env and use local Claude subscription login
  cc sub:work        Use another subscription profile, if registered
  cc api             Use the default API profile
  cc api:docker      Use a named API profile
  cc list            List registry profiles and cached health
  cc status          Print current state; --fresh/--refresh re-probes selected profile
  cc add-api NAME    Register a Claude Code API profile
                     Options: --base-url URL --env-key NAME --env KEY=VALUE (repeatable)
                     Prompts for missing base-url and the secret in a terminal.
                     --env adds non-secret per-profile vars (model mapping, compact window).
  cc add-sub NAME    Register a Claude Code subscription label
  cc remove NAME     Remove a Claude Code profile registration
  cc probe-model NAME [MODEL]  Set/clear health-probe model override
  cc default [NAME]  Show/set the default (primary) profile
  cc edit            Open the profile registry (profiles.json) in EDITOR
  cc health          Probe & report profile health table; --fresh/--refresh re-probes
  cc health-clear    Clear the health probe cache
  cc next            Cycle to the next enabled profile
  cc help            Show this help

Config:
  Registry: ~/.ai-env/profiles.json
  State:    ~/.ai-env/state.json
  Secrets:  ~/.ai-secrets/secrets.toml

After switching, run Claude Code separately: claude
Add commands only write profile metadata. Put real tokens in secrets.toml.
Without probe_model, Claude probes use ANTHROPIC_MODEL, ANTHROPIC_DEFAULT_HAIKU_MODEL, then a cheap fallback.
Legacy ~/.ai-secrets/*.env files are still accepted as a fallback.
EOF
      return
      ;;
    list)
      echo "Claude Code profiles ($AI_REGISTRY_PATH):"
      _ai_list_profiles claude
      return
      ;;
    status)
      _hr=0; _ai_has_fresh_flag "$@" && _hr=1
      echo "Claude Code state:"
      echo "  Registry: $AI_REGISTRY_PATH"
      echo "  State: $AI_STATE_PATH"
      echo "  Saved: $(_ai_saved_profile claude)"
      echo "  Process label: ${AI_CLAUDE_LABEL:-<unset>}"
      echo "  ANTHROPIC_BASE_URL: ${ANTHROPIC_BASE_URL:-<unset>}"
      echo "  ANTHROPIC_API_KEY: $(_ai_secret_preview "${ANTHROPIC_API_KEY:-}")"
      echo "  ANTHROPIC_AUTH_TOKEN: $(_ai_secret_preview "${ANTHROPIC_AUTH_TOKEN:-}")"
      profile_json="$(_ai_profile_json claude "${AI_CLAUDE_LABEL:-$(_ai_saved_profile claude)}")" && {
        echo "  Probe model: $(_ai_probe_model_for claude "$profile_json")"
        _ai_health_status_line claude "$profile_json" "$_hr"
      }
      _cc_external_status
      return
      ;;
    edit)
      _ai_registry_edit
      return
      ;;
    add-api)
      shift
      _cc_add_api "$@"
      return
      ;;
    add-sub)
      shift
      _cc_add_sub "$@"
      return
      ;;
    remove)
      shift
      _cc_remove_profile "$@"
      return
      ;;
    health)
      shift
      _hf=0; _ai_has_fresh_flag "$@" && _hf=1
      _ai_health_show claude "$_hf"
      return
      ;;
    default)
      shift; _ai_set_default claude "$@"; return
      ;;
    probe-model)
      shift; _ai_set_probe_model claude "$@"; return
      ;;
    health-clear)
      _ai_health_clear; echo "health cache cleared"; return
      ;;
    next)
      arg="$(_ai_next_profile claude)"
      ;;
  esac

  if [ -n "$arg" ]; then
    profile_json="$(_ai_profile_json claude "$arg")" || { echo "Unknown cc profile '$arg'. Add it to $AI_REGISTRY_PATH or run 'cc help'." >&2; return 1; }
  else
    profile_json="$(_ai_profile_json claude "$(_ai_healthy_profile claude)")" || return 1
  fi
  name="$(_ai_profile_value "$profile_json" name "")"
  _ai_save_profile claude "$name" || return
  _set_claude_env "$profile_json" || return
  _cc_print_status "$profile_json"
}

_codex_has_explicit_profile() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --profile|-p|--profile=*) return 0 ;;
    esac
  done
  return 1
}

_codex_first_token() {
  local skip_next=false arg
  for arg in "$@"; do
    if [ "$skip_next" = true ]; then
      skip_next=false
      continue
    fi
    case "$arg" in
      --) return 1 ;;
      -c|--config|-i|--image|-m|--model|-p|--profile|-s|--sandbox|-C|--cd|--add-dir|-a|--ask-for-approval|--remote|--remote-auth-token-env|--local-provider)
        skip_next=true
        continue
        ;;
      -*) continue ;;
      *) printf '%s\n' "$arg"; return 0 ;;
    esac
  done
  return 1
}

_codex_should_inject_profile() {
  local first
  _codex_has_explicit_profile "$@" && return 1
  first="$(_codex_first_token "$@")" || return 0
  case "$first" in
    login|logout|doctor|app|completion|update|features|help|cloud|app-server|remote-control|mcp-server|exec-server|mcp|plugin|sandbox|debug|apply|archive|unarchive)
      return 1
      ;;
  esac
  return 0
}

codex() {
  local saved profile_json profile_name
  saved="$(_ai_saved_profile codex)"
  profile_json="$(_ai_profile_json codex "${AI_CODEX_LABEL:-$saved}")" || profile_json="$(_ai_profile_json codex "$(_ai_default_profile codex)")" || return 1
  _set_codex_env "$profile_json" || return
  profile_name="$(_codex_profile_name "$profile_json")"
  if _codex_should_inject_profile "$@"; then
    if [ -f "$(_codex_profile_path "$profile_json")" ]; then
      command codex --profile "$profile_name" "$@"
    else
      command codex "$@"
    fi
  else
    command codex "$@"
  fi
}

# ===================== health subsystem (mirrors ai-env.ps1) =====================
# Real-wire probe (node https), TTL cache (~/.ai-env/health.json), on-demand.
AI_HEALTH_PATH="${AI_CONFIG_DIR}/health.json"
AI_HEALTH_TTL="${AI_HEALTH_TTL:-300}"
AI_HEALTH_DEGRADED_MS="${AI_HEALTH_DEGRADED_MS:-8000}"
AI_MCP_PATH="${AI_CONFIG_DIR}/mcp.toml"

_ai_claude_json_path() { printf '%s\n' "${AI_CLAUDE_JSON_PATH:-$HOME/.claude.json}"; }
_ai_codex_config_path() { printf '%s\n' "${AI_CODEX_CONFIG_PATH:-$HOME/.codex/config.toml}"; }

# Probe a profile via a real wire request. Echoes JSON:
# {"status","latencyMs","method","error"}. Never exports env.
_ai_probe_health() {
  local tool="$1" profile_json="$2"
  _ai_require_node || return 1
  node -e '
const fs=require("fs"),https=require("https"),http=require("http"),{URL}=require("url");
const tool=process.argv[1],P=JSON.parse(process.argv[2]),secretsPath=process.argv[3],router=process.argv[4];
const degradedMs=Number(process.env.AI_HEALTH_DEGRADED_MS||8000);
const out=(o)=>process.stdout.write(JSON.stringify(o));
const probeErr=(m)=>{if(!m)return"";const l=(""+m).toLowerCase();if(/timeout|canceled|timed out|httpclient\.timeout/.test(l))return"timeout";if(/ssl|handshake|eproto|sslv3|certificate|trust/.test(l))return"TLS handshake failed";if(/econnrefused|connection refused/.test(l))return"connection refused";if(/enotfound|getaddrinfo|nodata|getaddr|dns/.test(l))return"DNS failed";if(/econnreset|socket hang up|reset by peer|reset/.test(l))return"connection reset";return m;};
const mode=P.mode||"sub";
if(mode!=="api"){out({status:"skip",latencyMs:0,method:null,error:"subscription mode (no remote probe)"});process.exit(0);}
const parseSecrets=(file)=>{const s={};if(!fs.existsSync(file))return s;let c="";for(const line of fs.readFileSync(file,"utf8").split(/\r?\n/)){const t=line.trim();if(!t||t.startsWith("#"))continue;const sec=t.match(/^\[([^\]]+)\]\s*$/);if(sec){c=sec[1].trim();s[c]=s[c]||{};continue;}if(!c)continue;const m=t.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);if(!m)continue;let v=m[2].trim();if(v.startsWith("\"")){const mm=v.match(/^"((?:\\.|[^"])*)"/);if(mm){try{v=JSON.parse(mm[0]);}catch{v=mm[1];}}}else if(v.startsWith("'\''")){const mm=v.match(/^'\''([^'\'']*)'\''/);if(mm)v=mm[1];}else v=v.replace(/\s+#.*$/,"").trim();s[c][m[1]]=v;}return s;};
const expand=(x)=>!x?"":x.replace(/^~(?=\/|$)/,process.env.HOME||"");
const tomlStr=(file,key)=>{if(!fs.existsSync(file))return"";const re=new RegExp("^\\s*"+key.replace(/[.*+?^${}()|[\]\\]/g,"\\$&")+"\\s*=\\s*\"([^\"]*)\"");for(const line of fs.readFileSync(file,"utf8").split(/\r?\n/)){const m=line.match(re);if(m)return m[1];}return"";};const profileEnv=(p,key)=>p&&p.env&&typeof p.env==="object"&&p.env[key]?String(p.env[key]):"";const probeModelFor=(toolName,p,sec,legacyEnv,profPath)=>{if(p.probe_model)return String(p.probe_model);if(toolName==="claude")return sec.ANTHROPIC_MODEL||legacyEnv.ANTHROPIC_MODEL||profileEnv(p,"ANTHROPIC_MODEL")||process.env.ANTHROPIC_MODEL||sec.ANTHROPIC_DEFAULT_HAIKU_MODEL||legacyEnv.ANTHROPIC_DEFAULT_HAIKU_MODEL||profileEnv(p,"ANTHROPIC_DEFAULT_HAIKU_MODEL")||process.env.ANTHROPIC_DEFAULT_HAIKU_MODEL||"claude-3-5-haiku-20241022";return tomlStr(profPath,"model")||tomlStr(expand(p.home||"~/.codex")+"/config.toml","model")||"gpt-5.4-mini";};
const legacyEnv={};const legacy=expand(P.linux_secret||P.secret||"");if(legacy&&fs.existsSync(legacy)){for(const line of fs.readFileSync(legacy,"utf8").split(/\r?\n/)){const m=line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);if(m)legacyEnv[m[1]]=m[2].trim();}}
const secrets=parseSecrets(secretsPath);const sid=P.secret_id||(tool+"."+P.name);const sec=secrets[sid]||{};
let baseOrigin="",headers={},probeModel="",secretOk=false;
if(tool==="claude"){probeModel=probeModelFor(tool,P,sec,legacyEnv,"");let b=sec.ANTHROPIC_BASE_URL||legacyEnv.ANTHROPIC_BASE_URL||P.base_url||router;baseOrigin=b.replace(/\/+$/,"");const at=sec.ANTHROPIC_AUTH_TOKEN||legacyEnv.ANTHROPIC_AUTH_TOKEN||process.env.ANTHROPIC_AUTH_TOKEN||"";const ak=sec.ANTHROPIC_API_KEY||legacyEnv.ANTHROPIC_API_KEY||process.env.ANTHROPIC_API_KEY||"";headers={"anthropic-version":"2023-06-01"};if(at)headers["Authorization"]="Bearer "+at;if(ak)headers["x-api-key"]=ak;headers["User-Agent"]=P.probe_ua||"claude-cli/1.0.119 (external, cli)";secretOk=!!(at||ak);
}else{const profPath=expand((P.home||"~/.codex")+"/"+(P.codex_profile||P.profile||String(P.name||"").replace(":","-"))+".config.toml");probeModel=probeModelFor(tool,P,sec,legacyEnv,profPath);let b=tomlStr(profPath,"base_url");if(!b)b=tomlStr(expand(P.home||"~/.codex")+"/config.toml","openai_base_url");if(!b)b="built-in OpenAI/ChatGPT endpoint";baseOrigin=b.replace(/\/+$/,"");const k=sec.OPENAI_API_KEY||sec.CODEX_API_KEY||legacyEnv.OPENAI_API_KEY||"";headers=k?{"Authorization":"Bearer "+k}:{};headers["User-Agent"]=P.probe_ua||"codex_cli_rs/0.40.0 (external, cli)";secretOk=!!k;}
if(!baseOrigin||/^built-in/.test(baseOrigin)){out({status:"down",latencyMs:0,method:"none",error:"missing base_url"});process.exit(0);}
if(!secretOk){out({status:"down",latencyMs:0,method:"none",error:"missing credentials"});process.exit(0);}
let urls=[];
if(tool==="claude"){const apiBase=/\/v1$/.test(baseOrigin)?baseOrigin.replace(/\/v1$/,""):baseOrigin;urls.push(apiBase+"/v1/messages");}
else{const hasVer=/\/v\d+$/.test(baseOrigin);const apiBase=hasVer?baseOrigin:baseOrigin+"/v1";urls.push(apiBase+"/responses");urls.push(apiBase+"/chat/completions");}
const bodyFor=(u)=>u.endsWith("/responses")?JSON.stringify({model:probeModel,input:".",max_output_tokens:1}):JSON.stringify({model:probeModel,max_tokens:1,messages:[{role:"user",content:"."}]});
const decode=(x)=>String(x||"").replace(/\\u([0-9a-f]{4})/gi,(raw,hex)=>{const code=parseInt(hex,16);return code<0x20||(code>=0x7f&&code<0xa0)?"?":String.fromCharCode(code)}).replace(/[\u0000-\u001f\u007f-\u009f]/g,"?");
const compactBody=(raw)=>{try{const j=JSON.parse(raw);const msg=j?.error?.message||j?.message||j?.error||j?.type||"";if(msg)return decode(msg).replace(/\s+/g," ").trim();}catch{}return decode(raw).replace(/\s+/g," ").trim();};
const req=(u)=>new Promise((resolve)=>{const t0=Date.now();let done=false;const fin=(r)=>{if(!done){done=true;r.latencyMs=Date.now()-t0;resolve(r);}};const obj=new URL(u);const lib=obj.protocol==="http:"?http:https;const body=bodyFor(u);const r=lib.request(obj,{method:"POST",headers:{...headers,"Content-Type":"application/json","Content-Length":Buffer.byteLength(body)},timeout:20000},(res)=>{let d="";res.on("data",(c)=>d+=c);res.on("end",()=>{const detail=compactBody(d).slice(0,240);fin({ok:res.statusCode>=200&&res.statusCode<300,code:res.statusCode,body:d,err:detail?"HTTP "+res.statusCode+" "+detail:"HTTP "+res.statusCode});});});r.on("timeout",()=>{r.destroy();fin({ok:false,code:0,body:"",err:"timeout"});});r.on("error",(e)=>fin({ok:false,code:0,body:"",err:probeErr(e.message)}));r.write(body);r.end();});const modelUnsupported=(x)=>/no available providers|model_not_found|model not found|model does not exist|unknown model|unsupported model|model .*not supported|not support.*model|invalid model|model_not_supported|模型不存在|模型.*不存在|请检查模型代码/.test(decode(x).toLowerCase());
(async()=>{let lastErr=null,anyTransient=false;for(const u of urls){const r=await req(u);if(r.ok){let valid=true;try{const j=JSON.parse(r.body);if(u.endsWith("/messages"))valid=(Array.isArray(j.content)&&j.content.length>0)||j.type==="message";else if(u.endsWith("/responses"))valid=(Array.isArray(j.output)&&j.output.length>0)||j.output_text||j.status==="completed";else valid=Array.isArray(j.choices)&&j.choices.length>0;}catch{valid=false;}if(valid){const st=r.latencyMs>degradedMs?"degraded":"healthy";return out({status:st,latencyMs:r.latencyMs,method:"generation",error:null});}lastErr="200 but no generated content";}else{lastErr=r.err||(r.code?("HTTP "+r.code):"request failed");if(modelUnsupported(lastErr))return out({status:"degraded",latencyMs:r.latencyMs||0,method:"none",error:String(lastErr)});if(r.code===429||(r.code>=500&&r.code<600))anyTransient=true;}}
if(anyTransient)return out({status:"degraded",latencyMs:0,method:"none",error:String(lastErr)+(anyTransient?" (transient)":"")});
return out({status:"down",latencyMs:0,method:"none",error:String(lastErr)});
})();
' "$tool" "$profile_json" "$AI_SECRETS_PATH" "$CLAUDE_ROUTER_BASE_URL"
}

# Extract one field from a health-result JSON.
_ai_health_field() { node -e 'const j=JSON.parse(process.argv[1]||"{}");process.stdout.write(String(j[process.argv[2]]??""));' "$1" "$2"; }

# Read cached entry JSON for tool.name (empty if absent).
_ai_health_read_entry() {
  local tool="$1" name="$2"
  [ -f "$AI_HEALTH_PATH" ] || return 0
  node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const k=process.argv[2]+"."+process.argv[3];const e=j[k];if(e)process.stdout.write(JSON.stringify(e));' "$AI_HEALTH_PATH" "$tool" "$name"
}
_ai_health_store() {
  local tool="$1" name="$2" result_json="$3"
  mkdir -p "$AI_CONFIG_DIR"
  node -e 'const fs=require("fs");const p=process.argv[1],tool=process.argv[2],name=process.argv[3],r=JSON.parse(process.argv[4]);let j={};try{j=JSON.parse(fs.readFileSync(p,"utf8"));}catch{}j[tool+"."+name]=r;fs.writeFileSync(p,JSON.stringify(j,null,2)+"\n");' "$AI_HEALTH_PATH" "$tool" "$name" "$result_json"
}

# TTL-cached probe. Echoes result JSON. $3=1 forces a fresh probe.
# $4=1 -> cache-only: never probe (keeps list/status/switch instant; a stale or
# unprobed entry reads as "skip" ⏭). Use `health` / `status --refresh` to probe.
_ai_health_cached() {
  local tool="$1" profile_json="$2" fresh="${3:-0}" cache_only="${4:-0}" name result probed now stamped
  name="$(_ai_profile_value "$profile_json" name "")"
  if [ "$fresh" != "1" ]; then
    result="$(_ai_health_read_entry "$tool" "$name")"
    if [ -n "$result" ]; then
      probed="$(_ai_health_field "$result" probedAt)"
      now="$(node -e 'process.stdout.write(String(Math.floor(Date.now()/1000)))')"
      if [ -n "$probed" ] && [ "$probed" -gt 0 ] && [ $((now - probed)) -lt "$AI_HEALTH_TTL" ]; then
        printf '%s' "$result"; return 0
      fi
    fi
  fi
  if [ "$cache_only" = "1" ]; then
    printf '{"status":"skip","latencyMs":0,"method":null,"error":null,"probedAt":0}'
    return 0
  fi
  result="$(_ai_probe_health "$tool" "$profile_json")"
  stamped="$(node -e 'const r=JSON.parse(process.argv[1]);r.probedAt=Math.floor(Date.now()/1000);process.stdout.write(JSON.stringify(r));' "$result")"
  _ai_health_store "$tool" "$name" "$stamped" 2>/dev/null || true
  printf '%s' "$stamped"
}

_ai_health_cell() {
  local result="$1" hstatus code
  [ -n "$result" ] || { printf '?'; return; }
  hstatus="$(_ai_health_field "$result" status)"
  case "$hstatus" in
    healthy) printf '🟢%sms' "$(_ai_health_field "$result" latencyMs)";;
    degraded) code="$(printf '%s' "$(_ai_health_field "$result" error)" | grep -oE 'HTTP [0-9]{3}' | head -1 | grep -oE '[0-9]{3}')"; printf '🟡%s' "${code:-slow}";;
    down) code="$(printf '%s' "$(_ai_health_field "$result" error)" | grep -oE 'HTTP [0-9]{3}' | head -1 | grep -oE '[0-9]{3}')"; printf '🔴%s' "${code:-err}";;
    skip) printf '⏭';;
    *) printf '?';;
  esac
}
_ai_health_cell_cached() {
  local tool="$1" profile_json="$2" name result probed now
  name="$(_ai_profile_value "$profile_json" name "")"
  result="$(_ai_health_read_entry "$tool" "$name")"
  [ -n "$result" ] || { printf '⏭'; return; }
  probed="$(_ai_health_field "$result" probedAt)"
  now="$(node -e 'process.stdout.write(String(Math.floor(Date.now()/1000)))')"
  if [ -n "$probed" ] && [ "$probed" -gt 0 ] && [ $((now - probed)) -lt "$AI_HEALTH_TTL" ]; then
    _ai_health_cell "$result"
  else
    printf '⏭'
  fi
}

_ai_health_display_error() {
  local error="${1:-}" max="${2:-${AI_HEALTH_COLUMNS:-${COLUMNS:-120}}}" prefix="${3:-}"
  node -e '
const decode=(x)=>String(x||"").replace(/\\u([0-9a-f]{4})/gi,(raw,hex)=>{const code=parseInt(hex,16);return code<0x20||(code>=0x7f&&code<0xa0)?"?":String.fromCharCode(code)}).replace(/[\u0000-\u001f\u007f-\u009f]/g,"?");
const text=decode(process.argv[1]).replace(/\s+/g," ").trim();
const modelUnsupported=(x)=>/no available providers|model_not_found|model not found|model does not exist|unknown model|unsupported model|model .*not supported|not support.*model|invalid model|model_not_supported|模型不存在|模型.*不存在|请检查模型代码/.test(decode(x).toLowerCase());
const compactHttp=(s)=>{
  s=decode(s).replace(/\s+/g," ").trim();
  const m=s.match(/^(HTTP \d{3})(?:\s+(.+))?$/);
  if(!m)return s;
  const code=m[1], body=m[2]||"";
  if(!body)return code;
  try{const j=JSON.parse(body);const msg=j?.error?.message||j?.message||j?.error||j?.type||"";if(msg)return code+" "+String(msg).replace(/\s+/g," ").trim();}catch{}
  const mm=body.match(/"message"\s*:\s*"([^"]+)"/)||body.match(/message=([^,;}]+)/);
  if(mm)return code+" "+mm[1].replace(/\s+/g," ").trim();
  return s;
};
const short=(s)=>modelUnsupported(s)?"probe model unsupported; set probe_model":compactHttp(s);
const one=text.match(/^(POST\s+\/\S+\s+)(.+)$/);
const dual=text.match(/^(POST\s+\/\S+\s+->\s+)(.+?)(;\s+\/\S+\s+->\s+)(.+)$/);
let out=text;
if(dual)out=dual[1]+short(dual[2])+dual[3]+short(dual[4]);
else if(one)out=one[1]+short(one[2]);
else out=short(text);
const charWidth=(cp)=>cp===0||cp<32||(cp>=0x7f&&cp<0xa0)?0:(cp>=0x1100&&(cp<=0x115f||cp===0x2329||cp===0x232a||(cp>=0x2e80&&cp<=0xa4cf)||(cp>=0xac00&&cp<=0xd7a3)||(cp>=0xf900&&cp<=0xfaff)||(cp>=0xfe10&&cp<=0xfe19)||(cp>=0xfe30&&cp<=0xfe6f)||(cp>=0xff00&&cp<=0xff60)||(cp>=0xffe0&&cp<=0xffe6)||(cp>=0x1f300&&cp<=0x1faff)))?2:1;
const width=(s)=>{let n=0;for(const ch of String(s||""))n+=charWidth(ch.codePointAt(0));return n};
const trunc=(s,n)=>{s=String(s||"");if(width(s)<=n)return s;const suffix=n>3?"...":"",limit=Math.max(0,n-width(suffix));let result="",w=0;for(const ch of s){const cw=charWidth(ch.codePointAt(0));if(w+cw>limit)break;result+=ch;w+=cw}return result+suffix};
const requested=Number(process.argv[2]||120),max=Math.max(1,Math.min(120,requested>0?requested:120)),prefix=String(process.argv[3]||"");
process.stdout.write(trunc(prefix+(prefix&&out?"  ":"")+out,max));
' "$error" "$max" "$prefix"
}

_ai_healthy_profile() {
  local tool="$1" default ordered pj h st nm
  default="$(_ai_default_profile "$tool")"
  _ai_require_node || return 1
  ordered="$(node -e '
const fs=require("fs");const p=process.argv[1],tool=process.argv[2],def=process.argv[3];
let r={};try{r=JSON.parse(fs.readFileSync(p,"utf8"));}catch{}
const all=(r[tool]||[]).filter(x=>x.enabled!==false);
const d=all.find(x=>String(x.name)===def);const rest=all.filter(x=>String(x.name)!==def);
const out=d?[d,...rest]:rest;
for(const x of out)console.log(JSON.stringify(x));
' "$AI_REGISTRY_PATH" "$tool" "$default")" || return 1
  while IFS= read -r pj; do
    [ -n "$pj" ] || continue
    h="$(_ai_health_cached "$tool" "$pj" 0 1)"
    st="$(_ai_health_field "$h" status)"
    # Only auto-select a profile with a cached POSITIVE signal (healthy/
    # degraded) — an unprobed api profile (skip) or a subscription profile
    # (unprobeable, also skip) is NOT chosen, since we can't confirm it's up.
    # Run `cc health` first to populate health for real auto-failover.
    if [ "$st" = "healthy" ] || [ "$st" = "degraded" ]; then
      _ai_profile_value "$pj" name ""; return
    fi
  done <<<"$ordered"
  printf '%s\n' "$default"
}

_ai_set_probe_model() {
  local tool="$1"; shift
  local parsed name model
  parsed="$(_ai_parse_management_args "$@")" || return
  name="$(_ai_mgmt_positional "$parsed" 0)"
  [ -n "$name" ] || { echo "Usage: probe-model <name> [model]  (omit model to clear -> automatic probe model)" >&2; return 1; }
  model="$(_ai_mgmt_positional "$parsed" 1)"
  _ai_profile_json "$tool" "$name" >/dev/null || { echo "$tool profile '$name' not found." >&2; return 1; }
  local res
  res="$(node -e '
const fs=require("fs");const p=process.argv[1],tool=process.argv[2],query=String(process.argv[3]).toLowerCase(),model=process.argv[4];
let r={};try{r=JSON.parse(fs.readFileSync(p,"utf8"));}catch{}
for(const x of r[tool]||[]){const names=[x.name,...(x.aliases||[])].filter(Boolean).map(s=>String(s).toLowerCase());if(names.includes(query)){if(model)x.probe_model=model;else if(x.probe_model)delete x.probe_model;fs.writeFileSync(p,JSON.stringify(r,null,2)+"\n");process.stdout.write(x.name+"\t"+(model?"set":"clear"));process.exit(0);}}
process.exit(1);
' "$AI_REGISTRY_PATH" "$tool" "$name" "$model")" || { echo "$tool profile '$name' not found." >&2; return 1; }
  local pname act; pname="${res%%	*}"; act="${res#*	}"
  if [ "$act" = "set" ]; then echo "Set $tool '$pname' probe_model = $model"; else echo "Cleared $tool '$pname' probe_model (using automatic probe model)"; fi
}

_ai_set_default() {
  local tool="$1"; shift
  local parsed name cur
  parsed="$(_ai_parse_management_args "$@")" || return
  cur="$(_ai_default_profile "$tool")"
  name="$(_ai_mgmt_positional "$parsed" 0)"
  if [ -z "$name" ]; then echo "$tool default = $cur"; return; fi
  _ai_profile_json "$tool" "$name" >/dev/null || { echo "Unknown $tool profile '$name'." >&2; return 1; }
  node -e '
const fs=require("fs");const p=process.argv[1],tool=process.argv[2],name=process.argv[3];
let r={};try{r=JSON.parse(fs.readFileSync(p,"utf8"));}catch{}
r.defaults=r.defaults||{};r.defaults[tool]=name;fs.writeFileSync(p,JSON.stringify(r,null,2)+"\n");
' "$AI_REGISTRY_PATH" "$tool" "$name"
  echo "Set $tool default = $name"
}

_ai_health_clear() { rm -f "$AI_HEALTH_PATH"; }
_ai_health_sync_cache() {
  local tool="$1"
  [ -f "$AI_HEALTH_PATH" ] || return 0
  node -e '
const fs=require("fs");const hp=process.argv[1],tool=process.argv[2],rp=process.argv[3];
let r={};try{r=JSON.parse(fs.readFileSync(rp,"utf8"));}catch{}
const valid=new Set((r[tool]||[]).filter(x=>x.enabled!==false).map(x=>tool+"."+x.name));
let j={};try{j=JSON.parse(fs.readFileSync(hp,"utf8"));}catch{}
let changed=false;
for(const k of Object.keys(j)){if(k.startsWith(tool+".")&&!valid.has(k)){delete j[k];changed=true;}}
if(changed)fs.writeFileSync(hp,JSON.stringify(j,null,2)+"\n");
' "$AI_HEALTH_PATH" "$tool" "$AI_REGISTRY_PATH"
}

_ai_health_show() {
  # Delegate to the Node TUI helper (ai-health.mjs). The old shell version probed
  # via background `&` jobs, whose zsh/bash job-control notifications ([N] PID /
  # [N]+done) interleaved with ANSI redraw and broke the table. One foreground
  # Node process does the concurrency + timed redraw itself — no shell job
  # control, no [N] noise, save-anchor+clear-below rendering, ASCII spinner.
  local tool="$1" fresh="${2:-0}" flag=""
  [ "$fresh" = "1" ] && flag="--fresh"
  _ai_require_node >/dev/null 2>&1 || return 1
  local mjs="$HOME/.local/share/ai-env/ai-health.mjs"
  [ -f "$mjs" ] || { echo "health helper missing: $mjs" >&2; return 1; }
  node "$mjs" "$tool" $flag
}


# $3=1 forces a live probe (status --refresh); otherwise cache-only (instant).
_ai_health_status_line() {
  local tool="$1" profile_json="$2" fresh="${3:-0}" h cell err max
  if [ "$fresh" = "1" ]; then
    h="$(_ai_health_cached "$tool" "$profile_json" 1 0)"
  else
    h="$(_ai_health_cached "$tool" "$profile_json" 0 1)"
  fi
  cell="$(_ai_health_cell "$h")"
  err="$(_ai_health_field "$h" error)"
  max="${AI_HEALTH_COLUMNS:-${COLUMNS:-120}}"
  _ai_health_display_error "$err" "$max" "  Health: $cell"
  printf '\n'
}

# ===================== MCP module (mirrors ai-env.ps1) =====================
# ~/.ai-env/mcp.toml is the SSOT. `mcp sync` pushes to global targets:
#   Claude -> ~/.claude.json mcpServers (node JSON merge, atomic)
#   Codex  -> ~/.codex/config.toml [mcp_servers.NAME] (block edit)

# entry json -> [mcp.NAME] TOML block
_ai_mcp_toml_block() {
  node -e '
const e=JSON.parse(process.argv[1]);
const L=["[mcp."+e.name+"]"];
if(e.kind==="http"){L.push("url = \""+(e.url||"")+"\"");}
else{const cmd=(e.command||[]).map(x=>"\""+String(x)+"\"").join(", ");L.push("command = ["+cmd+"]");const env=e.env||{};const ks=Object.keys(env);if(ks.length)L.push("env = { "+ks.map(k=>k+" = \""+env[k]+"\"").join(", ")+" }");}
L.push("sync = ["+(e.sync||[]).map(x=>"\""+x+"\"").join(", ")+"]");
L.push("enabled = "+(e.enabled?"true":"false"));
process.stdout.write(L.join("\n"));
' "$1"
}
# read mcp.toml -> one entry JSON per line
_ai_mcp_read() {
  [ -f "$AI_MCP_PATH" ] || return 0
  node -e '
const fs=require("fs");
const pval=(raw)=>{const v=String(raw||"").trim();if(v.startsWith("\"")){const m=v.match(/^"((?:\\.|[^"])*)"/);if(m){try{return JSON.parse(m[0]);}catch{return m[1];}}}return v.replace(/\s+#.*$/,"").trim();};
const parr=(raw)=>{const o=[];for(const m of String(raw||"").matchAll(/"((?:\\.|[^"])*)"/g))o.push(m[1]);return o;};
const ptbl=(raw)=>{const h={};for(const m of String(raw||"").matchAll(/([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"((?:\\.|[^"])*)"/g))h[m[1]]=m[2];return h;};
let cur=null;const r={};
for(const line of fs.readFileSync(process.argv[1],"utf8").split(/\r?\n/)){const t=line.trim();if(!t||t.startsWith("#"))continue;const sec=t.match(/^\[mcp\.([^\]]+)\]\s*$/);if(sec){cur=sec[1].trim();r[cur]={name:cur,kind:"stdio",command:[],url:null,env:{},sync:["claude","codex"],enabled:true};continue;}if(/^\[/.test(t)){cur=null;continue;}if(!cur)continue;const m=t.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);if(!m)continue;const k=m[1],raw=m[2].trim(),e=r[cur];if(k==="command"){e.kind="stdio";e.command=parr(raw);}else if(k==="url"){e.kind="http";e.url=pval(raw);}else if(k==="env"){e.env=ptbl(raw);}else if(k==="sync"){e.sync=parr(raw);}else if(k==="enabled"){e.enabled=/true/.test(raw);}}
for(const n of Object.keys(r))console.log(JSON.stringify(r[n]));
' "$AI_MCP_PATH"
}

# Claude target upsert/remove. $2=entryJson (empty=remove)
_ai_mcp_claude_set() {
  local name="$1" entry="$2" p bak tmp
  p="$(_ai_claude_json_path)"; bak="$p.aienv.bak"; tmp="$p.tmp"
  [ -f "$p" ] && [ ! -f "$bak" ] && cp "$p" "$bak" 2>/dev/null || true
  node -e '
const fs=require("fs");const p=process.argv[1],tmp=process.argv[2],name=process.argv[3],hasE=process.argv[4]==="1",entry=process.argv[5];
let d={};try{if(fs.existsSync(p))d=JSON.parse(fs.readFileSync(p,"utf8"));}catch{}
const ms={};if(d.mcpServers&&typeof d.mcpServers==="object")for(const k of Object.keys(d.mcpServers))ms[k]=d.mcpServers[k];
if(hasE){const e=JSON.parse(entry);const o={};if(e.kind==="http"){o.type="http";o.url=e.url;}else{if(Array.isArray(e.command)&&e.command.length)o.command=String(e.command[0]);o.args=Array.isArray(e.command)&&e.command.length>1?e.command.slice(1):[];if(e.env&&Object.keys(e.env).length)o.env=e.env;}ms[name]=o;}else if(ms[name]){delete ms[name];}
d.mcpServers=ms;fs.writeFileSync(tmp,JSON.stringify(d,null,2));
' "$p" "$tmp" "$name" "$([ -n "$entry" ] && echo 1 || echo 0)" "$entry"
  mv "$tmp" "$p"
}
# Codex target upsert/remove. $2=TOML block (empty=remove)
_ai_mcp_codex_set() {
  local name="$1" block="$2" p header out
  p="$(_ai_codex_config_path)"; header="[mcp_servers.$name]"
  if [ ! -f "$p" ]; then
    [ -z "$block" ] && return 0
    mkdir -p "$(dirname "$p")"; : >"$p"
  fi
  out="$(awk -v h="$header" '
    { line=$0; sub(/^[ \t]+/,"",line); sub(/[ \t]+$/,"",line);
      if (line ~ /^\[/) { skip = (line == h) ? 1 : 0 }
      if (!skip) print
    }
  ' "$p")"
  if [ -n "$block" ]; then
    [ -n "$out" ] && out="$out"$'\n\n'
    out="$out$block"
  fi
  printf '%s\n' "$out" >"$p"
}

_ai_claude_mcp_names() {
  local p; p="$(_ai_claude_json_path)"
  [ -f "$p" ] || return 0
  node -e 'const fs=require("fs");try{const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));if(d.mcpServers)for(const k of Object.keys(d.mcpServers))console.log(k);}catch{}' "$p"
}
_ai_codex_mcp_test() {
  local p; p="$(_ai_codex_config_path)"
  [ -f "$p" ] || return 1
  grep -qE "^\[mcp_servers\.$(printf '%s' "$1" | sed 's/[][\.*/^$[]/\\&/g')\]" "$p"
}

_ai_mcp_sync() {
  local count; count="$(_ai_mcp_read | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then echo "No MCP servers in $AI_MCP_PATH. Run 'mcp edit'."; return; fi
  local entry name kind want cblock ups=0 rem=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).name)' "$entry")"
    want="$(node -e 'const e=JSON.parse(process.argv[1]);process.stdout.write((e.enabled&&e.sync&&e.sync.indexOf("claude")>=0)?"1":"0")' "$entry")"
    if [ "$want" = "1" ]; then _ai_mcp_claude_set "$name" "$entry"; ups=$((ups+1)); else _ai_mcp_claude_set "$name" ""; rem=$((rem+1)); fi
    want="$(node -e 'const e=JSON.parse(process.argv[1]);process.stdout.write((e.enabled&&e.sync&&e.sync.indexOf("codex")>=0)?"1":"0")' "$entry")"
    if [ "$want" = "1" ]; then
      cblock="$(_ai_mcp_codex_block_for_entry "$entry")"; _ai_mcp_codex_set "$name" "$cblock"; ups=$((ups+1))
    else
      _ai_mcp_codex_set "$name" ""; rem=$((rem+1))
    fi
  done < <(_ai_mcp_read)
  echo "MCP sync done: $ups upsert(s), $rem remove(s). Targets: Claude ($(_ai_claude_json_path)), Codex ($(_ai_codex_config_path))."
}
# entry json -> codex [mcp_servers.NAME] block
_ai_mcp_codex_block_for_entry() {
  node -e '
const e=JSON.parse(process.argv[1]);const L=["[mcp_servers."+e.name+"]"];
if(e.kind==="http"){L.push("url = \""+(e.url||"")+"\"");}
else{const cmd=(e.command||[]).map(x=>"\""+String(x)+"\"").join(", ");L.push("command = ["+cmd+"]");const env=e.env||{};const ks=Object.keys(env);if(ks.length)L.push("env = { "+ks.map(k=>k+" = \""+env[k]+"\"").join(", ")+" }");}
L.push("enabled = "+(e.enabled?"true":"false"));
process.stdout.write(L.join("\n"));
' "$1"
}

_ai_mcp_list() {
  local count; count="$(_ai_mcp_read | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then echo "No MCP servers in $AI_MCP_PATH. Run 'mcp edit'."; return; fi
  local entry name kind enabled sync cc cx
  printf '%-16s %-7s %-8s %-8s %-8s %s\n' Name Type Claude Codex Enabled Sync
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).name)' "$entry")"
    kind="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).kind)' "$entry")"
    enabled="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).enabled?"on":"off")' "$entry")"
    sync="$(node -e 'process.stdout.write((JSON.parse(process.argv[1]).sync||[]).join(","))' "$entry")"
    cc="-"; _ai_claude_mcp_names | grep -qxF "$name" && cc="yes"
    cx="-"; _ai_codex_mcp_test "$name" && cx="yes"
    printf '%-16s %-7s %-8s %-8s %-8s %s\n' "$name" "$kind" "$cc" "$cx" "$enabled" "$sync"
  done < <(_ai_mcp_read)
  echo "  (yes = present in target; run 'mcp sync' to align)"
}
_ai_mcp_get() {
  local name="$1" entry
  [ -n "$name" ] || { echo "Usage: mcp get NAME"; return; }
  entry="$(_ai_mcp_read | node -e 'const n=process.argv[1];let r="";for(let line of (require("fs").readFileSync(0,"utf8").split(/\r?\n/))){try{const e=JSON.parse(line);if(e.name===n){r=JSON.stringify(e);break;}}catch{}}process.stdout.write(r);' "$name")"
  [ -n "$entry" ] || { echo "No MCP server '$name' in mcp.toml."; return; }
  node -e '
const e=JSON.parse(process.argv[1]);console.log("mcp."+e.name+":");console.log("  kind    : "+e.kind);
if(e.kind==="http")console.log("  url     : "+e.url);else console.log("  command : "+(e.command||[]).join(" "));
const env=e.env||{};const ks=Object.keys(env);if(ks.length)console.log("  env     : "+ks.map(k=>k+"="+env[k]).join(", "));
console.log("  sync    : "+(e.sync||[]).join(", "));console.log("  enabled : "+e.enabled);
' "$entry"
  local cc="-" cx="-"
  _ai_claude_mcp_names | grep -qxF "$name" && cc="present"
  _ai_codex_mcp_test "$name" && cx="present"
  echo "  claude  : $cc"; echo "  codex   : $cx"
}
_ai_mcp_edit() {
  if [ ! -f "$AI_MCP_PATH" ]; then
    mkdir -p "$AI_CONFIG_DIR"
    cat >"$AI_MCP_PATH" <<'TOML'
# ~/.ai-env/mcp.toml - single source of truth for MCP servers (Claude Code + Codex).
# `mcp sync` pushes each enabled server to global targets:
#   Claude -> ~/.claude.json mcpServers
#   Codex  -> ~/.codex/config.toml [mcp_servers.NAME]
# A server is EITHER stdio (command = [...]) OR http (url = "...").
# sync = which tools (omit = both). enabled = false keeps it defined but skips it.

# [mcp.context7]
# command = ["npx", "-y", "@upstash/context7-mcp@3.2.4"]
# env = {}
# sync = ["claude", "codex"]
# enabled = false
TOML
    echo "Created starter mcp.toml at $AI_MCP_PATH"
  fi
  local ed="${EDITOR:-${VISUAL:-}}"
  [ -n "$ed" ] || ed="$(command -v cursor || command -v code || echo vi)"
  # strip --wait/-w so mcp edit opens and returns (non-blocking)
  local cmd rest
  cmd="$(printf '%s' "$ed" | awk '{for(i=1;i<=NF;i++)if($i!="--wait"&&$i!="-w")printf "%s%s",$i,(i<NF?" ":"");print""}' | awk '{print $1}')"
  echo "Opening $AI_MCP_PATH with $cmd ..."
  # Terminal editors (nano/vi/...) need the foreground TTY — run blocking. GUI
  # editors (cursor/code/...) launch a window and return — background + redirect.
  case "$cmd" in
    nano|vi|vim|nvim|emacs|micro|joe|ne|mg) "$cmd" "$AI_MCP_PATH" ;;
    *) ( "$cmd" "$AI_MCP_PATH" >/dev/null 2>&1 & ) 2>/dev/null ;;
  esac
}

# `cc edit` / `cx edit` — open the profile registry (profiles.json), where every
# profile's base_url, model, probe_model, mode etc. live. Non-blocking (no --wait).
_ai_registry_edit() {
  if [ ! -f "$AI_REGISTRY_PATH" ]; then
    echo "Registry not found: $AI_REGISTRY_PATH"
    return 1
  fi
  local ed="${EDITOR:-${VISUAL:-}}"
  [ -n "$ed" ] || ed="$(command -v cursor || command -v code || echo vi)"
  local cmd
  cmd="$(printf '%s' "$ed" | awk '{for(i=1;i<=NF;i++)if($i!="--wait"&&$i!="-w")printf "%s%s",$i,(i<NF?" ":"");print""}' | awk '{print $1}')"
  echo "Opening $AI_REGISTRY_PATH with $cmd ..."
  # Terminal editors (nano/vi/...) need the foreground TTY — run blocking. GUI
  # editors (cursor/code/...) launch a window and return — background + redirect.
  case "$cmd" in
    nano|vi|vim|nvim|emacs|micro|joe|ne|mg) "$cmd" "$AI_REGISTRY_PATH" ;;
    *) ( "$cmd" "$AI_REGISTRY_PATH" >/dev/null 2>&1 & ) 2>/dev/null ;;
  esac
}
_ai_mcp_pull() {
  local name="${1:-}" cp cj cx existing added=0 skipped=0 newblocks=""
  # existing mcp.toml names
  existing="$(_ai_mcp_read | node -e 'for(let l of require("fs").readFileSync(0,"utf8").split(/\r?\n/)){try{console.log(JSON.parse(l).name);}catch{}}')"
  # claude mcpServers
  cp="$(_ai_claude_json_path)"
  cj="$(node -e 'const fs=require("fs");try{const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const m=d.mcpServers||{};for(const k of Object.keys(m)){const e=m[k];const o={name:k,kind:"stdio",command:[],url:null,env:{},sync:["claude"],enabled:true};if(e.type==="http"||e.type==="sse"||e.url){o.kind="http";o.url=e.url;}else{const c=[];if(e.command){if(Array.isArray(e.command))c.push(...e.command);else c.push(String(e.command));}if(Array.isArray(e.args))c.push(...e.args);o.command=c;if(e.env&&typeof e.env==="object")o.env=e.env;}console.log(JSON.stringify(o));}}catch{}' "$cp")"
  # codex mcp_servers
  xp="$(_ai_codex_config_path)"
  xj="$(node -e 'const fs=require("fs");const p=process.argv[1];if(!fs.existsSync(p)){process.exit(0);}let cur=null;const r={};for(const line of fs.readFileSync(p,"utf8").split(/\r?\n/)){const t=line.trim();if(!t||t.startsWith("#"))continue;const s=t.match(/^\[mcp_servers\.([^\]]+)\]\s*$/);if(s){cur=s[1].trim();r[cur]={name:cur,command:[],url:null,env:{},enabled:true};continue;}if(/^\[/.test(t)){cur=null;continue;}if(!cur)continue;const m=t.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$/);if(!m)continue;const k=m[1],raw=m[2].trim();const e=r[cur];if(k==="command"){const arr=[];for(const mm of raw.matchAll(/"((?:\\.|[^"])*)"/g))arr.push(mm[1]);e.command=arr;}else if(k==="url"){e.url=raw.replace(/^"|"$/g,"");e.kind="http";}else if(k==="enabled"){e.enabled=/true/.test(raw);}}for(const n of Object.keys(r)){const e=r[n];const o={name:n,kind:e.url?"http":"stdio",command:e.command||[],url:e.url,env:{},sync:["codex"],enabled:e.enabled};console.log(JSON.stringify(o));}' "$xp")"
  # merge: for each unique name in cj+xj
  local all
  all="$(printf '%s\n%s\n' "$cj" "$xj" | node -e '
const lines=require("fs").readFileSync(0,"utf8").split(/\r?\n/);
const byName={};
for(const l of lines){if(!l.trim())continue;try{const e=JSON.parse(l);if(!byName[e.name])byName[e.name]={e:e,sync:new Set()};byName[e.name].sync.add(e.sync[0]);}catch{}}
for(const n of Object.keys(byName)){const x=byName[n];x.e.sync=Array.from(x.sync);console.log(JSON.stringify(x.e));}
')"
  if [ -n "$name" ]; then
    all="$(printf '%s\n' "$all" | node -e 'const n=process.argv[1];for(const l of require("fs").readFileSync(0,"utf8").split(/\r?\n/)){try{const e=JSON.parse(l);if(e.name===n){console.log(JSON.stringify(e));break;}}catch{}}' "$name")"
    [ -n "$all" ] || { echo "'$name' not found in Claude or Codex targets."; return; }
  fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    en="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).name)' "$e")"
    if printf '%s\n' "$existing" | grep -qxF "$en"; then skipped=$((skipped+1)); continue; fi
    newblocks="$newblocks"$'\n\n'"$(_ai_mcp_toml_block "$e")"
    added=$((added+1))
  done <<<"$all"
  if [ "$added" -gt 0 ]; then
    if [ ! -f "$AI_MCP_PATH" ]; then mkdir -p "$AI_CONFIG_DIR"; printf '# ~/.ai-env/mcp.toml - pulled from Claude Code & Codex. Edit freely; run mcp sync to push back.\n' >"$AI_MCP_PATH"; fi
    { [ -s "$AI_MCP_PATH" ] && printf '\n'; printf '%s\n' "${newblocks#$'\n\n'}"; } >>"$AI_MCP_PATH"
  fi
  echo "MCP pull: +$added added, $skipped skipped (already in mcp.toml). -> $AI_MCP_PATH"
}

mcp() {
  local arg="${1:-}"
  case "$arg" in
    ""|help|-h|--help)
      cat <<'EOF'
mcp - manage MCP servers across Claude Code & Codex from ~/.ai-env/mcp.toml

Usage:
  mcp                 Show this help
  mcp list            List servers + whether each target has them
  mcp edit            Open mcp.toml in EDITOR (creates a starter if absent)
  mcp sync            Push mcp.toml -> Claude (~/.claude.json) & Codex (~/.codex/config.toml)
  mcp pull [NAME]     Import existing MCP servers FROM Claude & Codex into mcp.toml
  mcp get NAME        Show one server's config + target status

mcp.toml is the single source of truth; edit it, then `mcp sync` (idempotent).
enabled = false keeps a server defined but skips it on sync.
sync = ["claude"] or ["codex"] limits a server to one tool (omit = both).
EOF
      ;;
    list) _ai_mcp_list ;;
    edit) _ai_mcp_edit ;;
    sync) _ai_mcp_sync ;;
    pull|import) shift; _ai_mcp_pull "$@" ;;
    get|show) _ai_mcp_get "${2:-}" ;;
    *) echo "Unknown mcp command '$arg'." >&2; return 1 ;;
  esac
}

_ai_init_saved_profiles() {
  local profile_json
  profile_json="$(_ai_profile_json codex "$(_ai_saved_profile codex)" 2>/dev/null)" && \
    _set_codex_env "$profile_json" >/dev/null 2>&1 || \
    echo "warning: could not initialize saved Codex profile" >&2

  profile_json="$(_ai_profile_json claude "$(_ai_saved_profile claude)" 2>/dev/null)" && \
    _set_claude_env "$profile_json" >/dev/null 2>&1 || \
    echo "warning: could not initialize saved Claude Code profile" >&2
}

_ai_init_saved_profiles
