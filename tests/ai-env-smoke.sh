#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${DOTFILES_SOURCE_DIR:-$REPO_DIR}"

smoke_mode="$(git -C "$REPO_DIR" ls-files -s -- tests/ai-env-smoke.sh | awk 'NR == 1 { print $1 }')"
if [ "$smoke_mode" != "100755" ]; then
  echo "tests/ai-env-smoke.sh must be tracked with mode 100755 (got '${smoke_mode:-missing}')" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "skipped ai-env shell smoke: node is not installed" >&2
  exit 0
fi

tmp_root="$(mktemp -d)"
tmp_home="$tmp_root/home"
debug_dir="$tmp_root/output"
trap 'status=$?; if [ "$status" -ne 0 ]; then echo "AI env shell smoke failed with exit $status." >&2; for file in "$debug_dir"/*; do [ -e "$file" ] || continue; echo "--- ${file##*/} ---" >&2; cat "$file" >&2; done; fi; rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_home/.local/share/ai-env" "$tmp_home/.ai-env" "$tmp_home/.ai-secrets" "$tmp_home/.codex" "$debug_dir"
cp "$SOURCE_DIR/src/shell/cxcc.sh" "$tmp_home/.local/share/ai-env/ai-env.sh"
cp "$SOURCE_DIR/src/shell/ai-health.mjs" "$tmp_home/.local/share/ai-env/ai-health.mjs"
cp "$SOURCE_DIR/templates/profiles.json" "$tmp_home/.ai-env/profiles.json"
cp "$SOURCE_DIR/templates/codex/sub.config.toml" "$tmp_home/.codex/sub.config.toml"
cp "$SOURCE_DIR/templates/codex/api.config.toml" "$tmp_home/.codex/api.config.toml"
mkdir -p "$tmp_home/.codex/sessions/2026/06/09"
cat >"$tmp_home/.codex/sessions/2026/06/09/rollout-2026-06-09T00-00-00-stats-smoke.jsonl" <<'EOF'
{"timestamp":"2026-06-09T00:00:00.000Z","type":"session_meta","payload":{"id":"stats-smoke","cwd":"/workspace"}}
{"timestamp":"2026-06-09T00:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":700,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200}}}}
EOF
printf '%s\n' \
  '{' \
  '  "codex": "sub",' \
  '  "claude": "api:docker"' \
  '}' >"$tmp_home/.ai-env/state.json"
cat >"$tmp_home/.ai-secrets/secrets.toml" <<'EOF'
[codex.api]
OPENAI_API_KEY = "sk-test-codex"

[codex.cxenvtest]
OPENAI_API_KEY = "sk-test-cxenv"

[claude.api-docker]
ANTHROPIC_BASE_URL = "https://claude.test"
ANTHROPIC_AUTH_TOKEN = "sk-test-token"

[claude.envtest]
ANTHROPIC_AUTH_TOKEN = "sk-test-envtoken"
EOF

run_step() {
  local name="$1"
  shift
  "$@" >"$debug_dir/$name.out" 2>"$debug_dir/$name.err" || {
    echo "command failed: $*" >&2
    return 1
  }
}

assert_contains() {
  local needle="$1" file="$2"
  grep -q "$needle" "$file" || {
    echo "missing expected text '$needle' in $file" >&2
    return 1
  }
}

assert_display_width() {
  local file="$1" max="$2" prefix="${3:-}"
  node -e '
const fs=require("fs"),max=Number(process.argv[2]),prefix=process.argv[3]||"";
const width=(s)=>{let w=0;for(const ch of s)w+=(ch.codePointAt(0)>=0x2e80&&ch.codePointAt(0)<=0xa4cf)?2:1;return w;};
for(const line of fs.readFileSync(process.argv[1],"utf8").split(/\r?\n/)){
  if(prefix&&!line.startsWith(prefix))continue;
  if(width(line)>max)throw new Error(`line width ${width(line)} exceeds ${max}: ${line}`);
}
' "$file" "$max" "$prefix"
}

(
  export HOME="$tmp_home"
  export AI_ENV_HOME="$tmp_home"
  export AI_CLAUDE_JSON_PATH="$tmp_home/.claude.json"
  export AI_CODEX_CONFIG_PATH="$tmp_home/.codex/config.toml"
  export CODEX_HOME="$tmp_home/.codex"
  # shellcheck source=/dev/null
  if ! . "$HOME/.local/share/ai-env/ai-env.sh"; then
    echo "failed to source ai-env.sh" >&2
    exit 1
  fi

  run_step cx-help cx help
  run_step cx-list cx list
  run_step cx-stats cx stats --days 365
  run_step cc-help cc help
  run_step cc-list cc list
  run_step cx-add-api cx add-api api:test --base-url https://router.test/v1 --model gpt-test
  run_step cx-add-sub cx add-sub sub:test
  run_step cc-add-api cc add-api api:test --base-url https://claude.test
  run_step cc-add-sub cc add-sub sub:test
  [ -f "$tmp_home/.codex/api-api-test.config.toml" ] || {
    echo "cx add-api did not write Codex config" >&2
    exit 1
  }
  run_step cx-managed-list cx list
  run_step cc-managed-list cc list
  run_step cx-remove-api cx remove api:test --delete-config
  run_step cx-remove-sub cx remove sub:test --delete-config
  run_step cc-remove-api cc remove api:test
  run_step cc-remove-sub cc remove sub:test

  assert_contains "cx - switch Codex state" "$debug_dir/cx-help.out"
  assert_contains "Auto-select a cached healthy Codex profile" "$debug_dir/cx-help.out"
  assert_contains "cx add-api NAME" "$debug_dir/cx-help.out"
  assert_contains "cx edit" "$debug_dir/cx-help.out"
  assert_contains "cx doctor" "$debug_dir/cx-help.out"
  assert_contains "cx next" "$debug_dir/cx-help.out"
  assert_contains "Codex profiles" "$debug_dir/cx-list.out"
  assert_contains "Health" "$debug_dir/cx-list.out"
  assert_contains "run 'cx health' to refresh" "$debug_dir/cx-list.out"
  assert_contains "Codex local token stats" "$debug_dir/cx-stats.out"
  assert_contains "Total: 1.2K (1200)" "$debug_dir/cx-stats.out"
  assert_contains "cc - switch Claude Code state" "$debug_dir/cc-help.out"
  assert_contains "Auto-select a cached healthy Claude Code profile" "$debug_dir/cc-help.out"
  assert_contains "cc add-api NAME" "$debug_dir/cc-help.out"
  assert_contains "cc edit" "$debug_dir/cc-help.out"
  assert_contains "cc next" "$debug_dir/cc-help.out"
  assert_contains "Claude Code profiles" "$debug_dir/cc-list.out"
  assert_contains "Health" "$debug_dir/cc-list.out"
  assert_contains "run 'cc health' to refresh" "$debug_dir/cc-list.out"
  assert_contains "Added Codex API profile 'api:test'" "$debug_dir/cx-add-api.out"
  assert_contains "Added Codex subscription profile 'sub:test'" "$debug_dir/cx-add-sub.out"
  assert_contains "Added Claude Code API profile 'api:test'" "$debug_dir/cc-add-api.out"
  assert_contains "Added Claude Code subscription profile 'sub:test'" "$debug_dir/cc-add-sub.out"
  assert_contains "api:test" "$debug_dir/cx-managed-list.out"
  assert_contains "sub:test" "$debug_dir/cx-managed-list.out"
  assert_contains "api:test" "$debug_dir/cc-managed-list.out"
  assert_contains "sub:test" "$debug_dir/cc-managed-list.out"
  assert_contains "Removed Codex profile 'api:test'" "$debug_dir/cx-remove-api.out"
  assert_contains "Removed Codex profile 'sub:test'" "$debug_dir/cx-remove-sub.out"
  assert_contains "Removed Claude Code profile 'api:test'" "$debug_dir/cc-remove-api.out"
  assert_contains "Removed Claude Code profile 'sub:test'" "$debug_dir/cc-remove-sub.out"
  [ ! -f "$tmp_home/.codex/api-api-test.config.toml" ] || {
    echo "cx remove --delete-config did not remove Codex config" >&2
    exit 1
  }
  if [ "${CODEX_HOME}" != "$tmp_home/.codex" ]; then
    echo "unexpected CODEX_HOME: got '${CODEX_HOME}', expected '$tmp_home/.codex'" >&2
    exit 1
  fi

  # per-profile env (--env): persisted in registry, exported on switch, cleared on switch-away
  export AI_ENV_NONINTERACTIVE=1
  run_step cc-add-env cc add-api envtest --base-url https://claude.test --env ANTHROPIC_DEFAULT_SONNET_MODEL=glm-test-sonnet --env CLAUDE_CODE_AUTO_COMPACT_WINDOW=987654
  run_step cx-add-env cx add-api cxenvtest --base-url https://router.test/v1 --env CODEX_EXTRA_FLAG=on
  assert_contains "ANTHROPIC_DEFAULT_SONNET_MODEL" "$tmp_home/.ai-env/profiles.json"
  assert_contains "Env: ANTHROPIC_DEFAULT_SONNET_MODEL" "$debug_dir/cc-add-env.out"

  cc envtest >"$debug_dir/cc-envtest.out" 2>&1
  [ "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" = "glm-test-sonnet" ] || { echo "cc switch did not export profile env" >&2; exit 1; }
  [ "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" = "987654" ] || { echo "cc switch did not export compact window" >&2; exit 1; }
  cc api:docker >"$debug_dir/cc-env-away.out" 2>&1
  [ -z "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" ] || { echo "cc switch-away did not clear profile env (leak)" >&2; exit 1; }
  cx cxenvtest >"$debug_dir/cx-envtest.out" 2>&1
  [ "${CODEX_EXTRA_FLAG:-}" = "on" ] || { echo "cx switch did not export profile env" >&2; exit 1; }
  cx api >"$debug_dir/cx-env-away.out" 2>&1
  [ -z "${CODEX_EXTRA_FLAG:-}" ] || { echo "cx switch-away did not clear profile env (leak)" >&2; exit 1; }
  assert_contains "API local check: profile file=true; key=true" "$debug_dir/cx-env-away.out"

  # --- health: mock the network probe, test cache/cell/select/probe-model/default ---
  probe_log="$debug_dir/probe.log"
  : >"$probe_log"
  _ai_probe_health() {
    printf '%s\n' "$(_ai_profile_value "$2" name "")" >>"$probe_log"
    case "$(_ai_profile_value "$2" name "")" in
      hgood) printf '%s' '{"status":"healthy","latencyMs":120,"method":"generation","error":null}';;
      hbad)  printf '%s' '{"status":"down","latencyMs":0,"method":"none","error":"HTTP 401"}';;
      hslow) printf '%s' '{"status":"degraded","latencyMs":9999,"method":"generation","error":"HTTP 429 (transient)"}';;
      hcn)   printf '%s' '{"status":"degraded","latencyMs":10,"method":"none","error":"POST /v1/messages HTTP 400 {\"type\":\"error\",\"error\":{\"message\":\"[1211][模型不存在，请检查模型代码。]\"}}"}';;
      hescaped) printf '%s' '{"status":"degraded","latencyMs":10,"method":"none","error":"POST /v1/messages HTTP 500 {\"error\":{\"message\":\"\\u539f\\u56e0\\u8d85\\u957f\\uff1a\\u8fd9\\u662f\\u4e00\\u6bb5\\u4e2d\\u6587\\u9519\\u8bef\\u539f\\u56e0\"}} trailing"}';;
      *)     printf '%s' '{"status":"down","latencyMs":0,"method":"none","error":"HTTP 404"}';;
    esac
  }
  cc add-api hgood --base-url https://h.test >/dev/null 2>&1
  cc add-api hbad  --base-url https://h.test >/dev/null 2>&1
  cc add-api hslow --base-url https://h.test >/dev/null 2>&1
  cc add-api hcn   --base-url https://h.test >/dev/null 2>&1
  cc add-api hescaped --base-url https://h.test >/dev/null 2>&1
  cat >>"$AI_SECRETS_PATH" <<'EOF'

[claude.hgood]
ANTHROPIC_AUTH_TOKEN = "sk-test-hgood"
EOF
  cc probe-model hgood my-sonnet >/dev/null 2>&1
  [ "$(_ai_profile_value "$(_ai_profile_json claude hgood)" probe_model "")" = "my-sonnet" ] || { echo "probe-model set failed" >&2; exit 1; }
  cc probe-model hgood >/dev/null 2>&1
  [ -z "$(_ai_profile_value "$(_ai_profile_json claude hgood)" probe_model "")" ] || { echo "probe-model clear failed" >&2; exit 1; }
  cc add-api envmodel --base-url https://h.test --env ANTHROPIC_DEFAULT_HAIKU_MODEL=env-haiku >/dev/null 2>&1
  [ "$(_ai_profile_value "$(_ai_profile_json claude envmodel)" env "")" != "" ] || { echo "profile env missing after add-api --env" >&2; exit 1; }
  cc default hbad >/dev/null 2>&1
  [ "$(_ai_default_profile claude)" = "hbad" ] || { echo "default set failed" >&2; exit 1; }
  rm -f "$AI_HEALTH_PATH"
  pj="$(_ai_profile_json claude hgood)"
  r1="$(_ai_health_cached claude "$pj" 0)"
  [ -f "$AI_HEALTH_PATH" ] || { echo "health.json not written" >&2; exit 1; }
  case "$(_ai_health_cell "$r1")" in 🟢120ms) :;; *) echo "health cell wrong: $(_ai_health_cell "$r1")" >&2; exit 1;; esac
  [ "$(_ai_healthy_profile claude)" = "hgood" ] || { echo "auto-select did not skip down -> hgood" >&2; exit 1; }
  cc hgood >"$debug_dir/cc-switch-hgood.out" 2>&1
  assert_contains "Probe model: claude-3-5-haiku-20241022" "$debug_dir/cc-switch-hgood.out"
  assert_contains "Health:" "$debug_dir/cc-switch-hgood.out"
  probe_before="$(wc -l <"$probe_log")"
  cc status >"$debug_dir/cc-status.out" 2>&1
  assert_contains "Probe model: claude-3-5-haiku-20241022" "$debug_dir/cc-status.out"
  assert_contains "Health:" "$debug_dir/cc-status.out"
  [ "$(wc -l <"$probe_log")" = "$probe_before" ] || { echo "cc status without --fresh probed live" >&2; exit 1; }
  cc status --fresh >"$debug_dir/cc-status-fresh.out" 2>&1
  [ "$(wc -l <"$probe_log")" -gt "$probe_before" ] || { echo "cc status --fresh did not probe live" >&2; exit 1; }
  assert_contains "Probe model:" "$debug_dir/cc-status-fresh.out"
  assert_contains "Health:" "$debug_dir/cc-status-fresh.out"
  short_health_note="$(_ai_health_display_error 'POST /v1/messages HTTP 400 {"type":"error","error":{"message":"[1211][模型不存在，请检查模型代码。]"}}')"
  case "$short_health_note" in
    *"probe model unsupported; set probe_model"*) : ;;
    *) echo "Chinese unsupported model health note not shortened: $short_health_note" >&2; exit 1 ;;
  esac
  _ai_save_profile claude hcn
  unset AI_CLAUDE_LABEL
  cc status --fresh >"$debug_dir/cc-status-hcn-fresh.out" 2>&1
  assert_contains "probe model unsupported; set probe_model" "$debug_dir/cc-status-hcn-fresh.out"
  assert_contains "Probe model:" "$debug_dir/cc-status-hcn-fresh.out"

  escaped_health_note="$(_ai_health_display_error 'POST /v1/messages HTTP 500 {"error":{"message":"\u539f\u56e0\u8d85\u957f\uff1a\u8fd9\u662f\u4e00\u6bb5\u4e2d\u6587\u9519\u8bef\u539f\u56e0"}} trailing')"
  case "$escaped_health_note" in
    *"原因超长"*) : ;;
    *) echo "escaped Chinese health note was not decoded: $escaped_health_note" >&2; exit 1 ;;
  esac
  case "$escaped_health_note" in
    *'\u'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*) echo "Unicode escape leaked: $escaped_health_note" >&2; exit 1 ;;
  esac
  control_health_note="$(_ai_health_display_error $'HTTP 500 \033[2J原因超长')"
  case "$control_health_note" in
    *$'\033'*) echo "ESC control character leaked: $control_health_note" >&2; exit 1 ;;
    *"原因超长"*) : ;;
    *) echo "control sanitization damaged Chinese detail: $control_health_note" >&2; exit 1 ;;
  esac
  empty_health_note="$(_ai_health_display_error '' 5 '  Health: OK')"
  [ "${#empty_health_note}" -le 5 ] || { echo "empty health detail bypassed width cap: $empty_health_note" >&2; exit 1; }

  _ai_save_profile claude hescaped
  unset AI_CLAUDE_LABEL
  COLUMNS=80 cc status --fresh >"$debug_dir/cc-status-hescaped-fresh.out" 2>&1
  assert_contains "原因超长" "$debug_dir/cc-status-hescaped-fresh.out"
  if grep -Eq '\\u[0-9a-fA-F]{4}' "$debug_dir/cc-status-hescaped-fresh.out"; then
    echo "status leaked a Unicode escape" >&2; exit 1
  fi
  assert_display_width "$debug_dir/cc-status-hescaped-fresh.out" 80 "  Health:"

  bounded_registry="$debug_dir/bounded-profiles.json"
  bounded_health="$debug_dir/bounded-health.json"
  printf '%s\n' '{"schema":1,"defaults":{"claude":"hescaped"},"codex":[],"claude":[{"name":"hescaped","aliases":[],"mode":"api","base_url":"https://h.test","secret_id":"claude.hescaped"}]}' >"$bounded_registry"
  node -e 'const fs=require("fs");const p=process.argv[1],error="HTTP 500 \u001b[2J"+process.argv[2];fs.writeFileSync(p,JSON.stringify({"claude.hescaped":{status:"degraded",latencyMs:10,method:"none",error,probedAt:Math.floor(Date.now()/1000)}},null,2)+"\n")' "$bounded_health" '\u539f\u56e0\u8d85\u957f\uff1a\u8fd9\u662f\u4e00\u6bb5\u4e2d\u6587\u9519\u8bef\u539f\u56e0'
  AI_REGISTRY_PATH="$bounded_registry" AI_HEALTH_PATH="$bounded_health" AI_HEALTH_COLUMNS=80 node "$tmp_home/.local/share/ai-env/ai-health.mjs" claude >"$debug_dir/cc-health-bounded.out" 2>&1
  assert_contains "原因超" "$debug_dir/cc-health-bounded.out"
  if grep -Eq '\\u[0-9a-fA-F]{4}' "$debug_dir/cc-health-bounded.out"; then
    echo "health table leaked a Unicode escape" >&2; exit 1
  fi
  if grep -q $'\033' "$debug_dir/cc-health-bounded.out"; then
    echo "health table leaked an ESC control character" >&2; exit 1
  fi
  assert_display_width "$debug_dir/cc-health-bounded.out" 80
  _ai_save_profile claude api:docker
  cc api:docker >/dev/null 2>&1
  cc api:docker >"$debug_dir/cc-switch-api-docker.out" 2>&1
  assert_contains "API local check: auth=true; url=true" "$debug_dir/cc-switch-api-docker.out"
  cc health-clear; [ ! -f "$AI_HEALTH_PATH" ] || { echo "health-clear failed" >&2; exit 1; }
  mcp list >/dev/null 2>&1 || { echo "mcp command failed" >&2; exit 1; }

  # --- mcp: offline (file-only, no network) ---
  cat >"$AI_MCP_PATH" <<'TOML'
[mcp.context7]
command = ["npx", "-y", "@upstash/context7-mcp"]
sync = ["claude", "codex"]
enabled = true

[mcp.figma]
url = "https://mcp.figma.com/mcp"
sync = ["codex"]
enabled = false
TOML
  echo '{"mcpServers":{}}' >"$AI_CLAUDE_JSON_PATH"
  : >"$AI_CODEX_CONFIG_PATH"
  mcp sync >/dev/null 2>&1
  grep -q '"context7"' "$AI_CLAUDE_JSON_PATH" || { echo "mcp sync: claude missing context7" >&2; exit 1; }
  ! grep -q '"figma"' "$AI_CLAUDE_JSON_PATH" || { echo "mcp sync: claude should not have disabled figma" >&2; exit 1; }
  grep -q '\[mcp_servers.context7\]' "$AI_CODEX_CONFIG_PATH" || { echo "mcp sync: codex missing context7" >&2; exit 1; }
  ! grep -q '\[mcp_servers.figma\]' "$AI_CODEX_CONFIG_PATH" || { echo "mcp sync: codex should not have disabled figma" >&2; exit 1; }
  grep -q context7 < <(mcp list) || { echo "mcp list missing context7" >&2; exit 1; }
  rm -f "$AI_MCP_PATH"
  echo '{"mcpServers":{"newone":{"command":"echo"}}}' >"$AI_CLAUDE_JSON_PATH"
  : >"$AI_CODEX_CONFIG_PATH"
  grep -q '+1 added' < <(mcp pull 2>&1) || { echo "mcp pull did not add newone" >&2; exit 1; }
  grep -q '\[mcp.newone\]' "$AI_MCP_PATH" || { echo "mcp pull did not write newone" >&2; exit 1; }
)

if command -v zsh >/dev/null 2>&1; then
  run_step zsh-ai-env env \
    HOME="$tmp_home" \
    AI_ENV_HOME="$tmp_home" \
    AI_CLAUDE_JSON_PATH="$tmp_home/.claude.json" \
    AI_CODEX_CONFIG_PATH="$tmp_home/.codex/config.toml" \
    CODEX_HOME="$tmp_home/.codex" \
    zsh -f -ic '
    source "$HOME/.local/share/ai-env/ai-env.sh"
    command -v node >/dev/null
    toml_base_url="$(_ai_toml_value "$HOME/.codex/api.config.toml" base_url)"
    [ "$toml_base_url" = "https://api.example.com/v1" ]
    _ai_probe_health() { printf "{\"status\":\"skip\",\"latencyMs\":0,\"method\":null,\"error\":\"mock\"}"; }
    cx list
    cc status
  '
  assert_contains "Codex profiles" "$debug_dir/zsh-ai-env.out"
  assert_contains "Saved: api:docker" "$debug_dir/zsh-ai-env.out"
  assert_contains "ANTHROPIC_AUTH_TOKEN: sk-test-...oken" "$debug_dir/zsh-ai-env.out"
  if [ -s "$debug_dir/zsh-ai-env.err" ]; then
    echo "unexpected zsh stderr:" >&2
    cat "$debug_dir/zsh-ai-env.err" >&2
    exit 1
  fi
fi

echo "AI env shell smoke check passed."
