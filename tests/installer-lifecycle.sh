#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"
for required_file in "$INSTALLER" "$REPO_ROOT/load.ps1" "$REPO_ROOT/load.sh"; do
  if [ ! -f "$required_file" ]; then
    echo "Required installer file is missing: $required_file" >&2
    exit 1
  fi
done

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  else
    echo "A SHA-256 tool is required." >&2
    return 1
  fi
}

assert_true() {
  local message="$1"
  shift
  "$@" || {
    echo "$message" >&2
    return 1
  }
}

tmp_root="$(mktemp -d)"
test_home="$tmp_root/home"
install_root="$test_home/.local/share/cxcc"
unrelated_cwd="$tmp_root/unrelated cwd"
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$test_home/.ai-env" "$test_home/.ai-secrets" "$test_home/.codex" "$test_home/.claude" "$unrelated_cwd"
cp "$REPO_ROOT/templates/profiles.json" "$test_home/.ai-env/profiles.json"
printf '# sentinel secret store\n' >"$test_home/.ai-secrets/secrets.toml"
printf 'model = "sentinel"\n' >"$test_home/.codex/config.toml"
printf '{"sentinel":true}\n' >"$test_home/.claude/settings.json"

sentinel_paths=(
  "$test_home/.ai-env/profiles.json"
  "$test_home/.ai-secrets/secrets.toml"
  "$test_home/.codex/config.toml"
  "$test_home/.claude/settings.json"
)
sentinel_hashes=()
for sentinel_path in "${sentinel_paths[@]}"; do
  sentinel_hashes+=("$(sha256_file "$sentinel_path")")
done

assert_state_preserved() {
  local index path actual
  for index in "${!sentinel_paths[@]}"; do
    path="${sentinel_paths[$index]}"
    [ -f "$path" ] || { echo "User state file was removed: $path" >&2; return 1; }
    actual="$(sha256_file "$path")"
    [ "$actual" = "${sentinel_hashes[$index]}" ] || { echo "User state file changed: $path" >&2; return 1; }
  done
}

new_test_archive() {
  local version="$1" payload="$tmp_root/payload-$1" archive="$tmp_root/cxcc-$1.tar.gz"
  mkdir -p "$payload"
  cp -R "$REPO_ROOT/src" "$payload/src"
  cp -R "$REPO_ROOT/templates" "$payload/templates"
  cp "$REPO_ROOT/load.ps1" "$REPO_ROOT/load.sh" "$payload/"
  printf '\nCXCC_TEST_PAYLOAD_VERSION=%q\n' "$version" >>"$payload/src/shell/cxcc.sh"
  printf '%s' "$version" >"$payload/VERSION"
  tar -czf "$archive" -C "$payload" .
  printf '%s\t%s\n' "$archive" "$(sha256_file "$archive")"
}

current_field() {
  local field="$1"
  sed -n "s/.*\"${field}\":\"\([^\"]*\)\".*/\1/p" "$install_root/current.json"
}

assert_current() {
  local expected_version="$1" expected_previous="$2" actual_previous
  [ "$(current_field version)" = "$expected_version" ] || { echo "Expected current version $expected_version." >&2; return 1; }
  actual_previous="$(current_field previous)"
  [ "$actual_previous" = "$expected_previous" ] || { echo "Expected previous version '$expected_previous', got '$actual_previous'." >&2; return 1; }
  grep -q '"schema":1' "$install_root/current.json" || { echo "current.json schema is not 1." >&2; return 1; }
}

assert_loader_works() {
  local expected_version="$1"
  HOME="$test_home" AI_ENV_HOME="$test_home" bash -c '
    set -Eeuo pipefail
    cd -- "$1"
    # shellcheck source=/dev/null
    . "$2"
    type cx >/dev/null
    type cc >/dev/null
    type mcp >/dev/null
    cx help >/dev/null
    [ -n "${CXCC_HEALTH_HELPER:-}" ]
    [ -f "$CXCC_HEALTH_HELPER" ]
    [ "$CXCC_TEST_PAYLOAD_VERSION" = "$3" ]
  ' _ "$unrelated_cwd" "$install_root/load.sh" "$expected_version"
  if command -v zsh >/dev/null 2>&1; then
    HOME="$test_home" AI_ENV_HOME="$test_home" zsh -f -c '
      cd "$1"
      source "$2"
      type cx >/dev/null
      type cc >/dev/null
      type mcp >/dev/null
      [ "$CXCC_TEST_PAYLOAD_VERSION" = "$3" ]
    ' _ "$unrelated_cwd" "$install_root/load.sh" "$expected_version"
  fi
}

IFS=$'\t' read -r v1_archive v1_sha < <(new_test_archive "v0.1.0")
IFS=$'\t' read -r v2_archive v2_sha < <(new_test_archive "v0.2.0")

dangling_target="$tmp_root/dangling-target"
dangling_root="$tmp_root/dangling/cxcc"
mkdir -p "$(dirname "$dangling_root")"
if ln -s "$dangling_target" "$dangling_root" 2>/dev/null && [ -L "$dangling_root" ]; then
  if HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version v0.1.0 --artifact "$v1_archive" --sha256 "$v1_sha" --install-root "$dangling_root"; then
    echo "A dangling symlink install root was accepted." >&2
    exit 1
  fi
  [ ! -e "$dangling_target" ] || { echo "Rejected dangling symlink created its target." >&2; exit 1; }
fi

recovery_root="$tmp_root/recovery/cxcc"
if HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version v9.9.9 --artifact "$v1_archive" --sha256 "$v1_sha" --install-root "$recovery_root"; then
  echo "An artifact with a mismatched VERSION was accepted." >&2
  exit 1
fi
HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version v0.1.0 --artifact "$v1_archive" --sha256 "$v1_sha" --install-root "$recovery_root"
[ "$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$recovery_root/current.json")" = "v0.1.0" ] || { echo "A failed first install prevented a valid retry." >&2; exit 1; }
HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --uninstall --install-root "$recovery_root"

HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version v0.1.0 --artifact "$v1_archive" --sha256 "$v1_sha" --install-root "$install_root"
assert_true "Clean install did not create v0.1.0." test -d "$install_root/versions/v0.1.0"
assert_true "Clean install did not create load.ps1." test -f "$install_root/load.ps1"
assert_true "Clean install did not create load.sh." test -f "$install_root/load.sh"
assert_true "Clean install did not create the cxcc root marker." grep -qx 'cxcc-install-root-v1' "$install_root/.cxcc-root"
assert_current v0.1.0 ""
assert_state_preserved
assert_loader_works v0.1.0
root_load_ps1_sha="$(sha256_file "$install_root/load.ps1")"
root_load_sh_sha="$(sha256_file "$install_root/load.sh")"

pointer_before_repeat="$(sha256_file "$install_root/current.json")"
HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version v0.1.0 --artifact "$v1_archive" --sha256 "$v1_sha" --install-root "$install_root"
version_count=0
for version_directory in "$install_root/versions"/*; do
  [ ! -d "$version_directory" ] || version_count=$((version_count + 1))
done
[ "$version_count" = "1" ] || { echo "Repeat install created an extra version directory." >&2; exit 1; }
[ "$(sha256_file "$install_root/current.json")" = "$pointer_before_repeat" ] || { echo "Repeat install changed current.json." >&2; exit 1; }
assert_state_preserved

cp "$install_root/current.json" "$tmp_root/current-before-failure.json"
if HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version v0.2.0 --artifact "$v2_archive" --sha256 "$(printf '0%.0s' {1..64})" --install-root "$install_root"; then
  echo "A mismatched SHA-256 was accepted." >&2
  exit 1
fi
[ ! -e "$install_root/versions/v0.2.0" ] || { echo "Failed checksum left a final v0.2.0 directory." >&2; exit 1; }
cmp -s "$tmp_root/current-before-failure.json" "$install_root/current.json" || { echo "Failed checksum changed current.json." >&2; exit 1; }
assert_loader_works v0.1.0
assert_state_preserved

if HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version ../escape --artifact "$v2_archive" --sha256 "$v2_sha" --install-root "$install_root"; then
  echo "An unsafe version was accepted." >&2
  exit 1
fi
[ ! -e "$install_root/escape" ] || { echo "Unsafe version escaped the versions directory." >&2; exit 1; }

IFS=$'\t' read -r link_archive link_sha < <(new_test_archive "v0.3.0")
link_payload="$tmp_root/payload-v0.3.0"
if ln -s "$tmp_root" "$link_payload/unsafe-link" 2>/dev/null && [ -L "$link_payload/unsafe-link" ]; then
  tar -czf "$link_archive" -C "$link_payload" .
  link_sha="$(sha256_file "$link_archive")"
  if HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version v0.3.0 --artifact "$link_archive" --sha256 "$link_sha" --install-root "$install_root"; then
    echo "An artifact containing a symlink was accepted." >&2
    exit 1
  fi
  [ ! -e "$install_root/versions/v0.3.0" ] || { echo "Rejected link artifact left a final version directory." >&2; exit 1; }
fi

HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --version v0.2.0 --artifact "$v2_archive" --sha256 "$v2_sha" --install-root "$install_root"
assert_current v0.2.0 v0.1.0
assert_true "Upgrade removed v0.1.0." test -d "$install_root/versions/v0.1.0"
assert_true "Upgrade did not install v0.2.0." test -d "$install_root/versions/v0.2.0"
assert_loader_works v0.2.0
[ "$(sha256_file "$install_root/load.ps1")" = "$root_load_ps1_sha" ] || { echo "Upgrade replaced stable root load.ps1." >&2; exit 1; }
[ "$(sha256_file "$install_root/load.sh")" = "$root_load_sh_sha" ] || { echo "Upgrade replaced stable root load.sh." >&2; exit 1; }
assert_state_preserved

HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --rollback --install-root "$install_root"
assert_current v0.1.0 v0.2.0
assert_loader_works v0.1.0
assert_state_preserved

unrecognized_root="$tmp_root/unrecognized/cxcc"
mkdir -p "$unrecognized_root"
printf 'keep\n' >"$unrecognized_root/keep.txt"
if HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --uninstall --install-root "$unrecognized_root"; then
  echo "Uninstall accepted an unrecognized cxcc root." >&2
  exit 1
fi
[ -f "$unrecognized_root/keep.txt" ] || { echo "Rejected uninstall removed unrelated data." >&2; exit 1; }

HOME="$test_home" AI_ENV_HOME="$test_home" bash "$INSTALLER" --uninstall --install-root "$install_root"
[ ! -e "$install_root" ] || { echo "Uninstall did not remove the cxcc install root." >&2; exit 1; }
assert_state_preserved

echo "cxcc shell installer lifecycle tests passed."
