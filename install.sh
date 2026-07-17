#!/usr/bin/env bash

set -Eeuo pipefail

repository="Tim-1e/cxcc"
root_marker_content="cxcc-install-root-v1"
version=""
artifact_path=""
expected_sha256=""
install_root="${CXCC_HOME:-$HOME/.local/share/cxcc}"
action="install"
download_root=""
staging_path=""
marker_temp=""

fail() {
  echo "$*" >&2
  exit 1
}

cleanup() {
  [ -z "$staging_path" ] || rm -rf "$staging_path"
  [ -z "$marker_temp" ] || rm -f "$marker_temp"
  [ -z "$download_root" ] || rm -rf "$download_root"
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) [ "$#" -ge 2 ] || fail "--version requires a value."; version="$2"; shift 2 ;;
    --artifact) [ "$#" -ge 2 ] || fail "--artifact requires a value."; artifact_path="$2"; shift 2 ;;
    --sha256) [ "$#" -ge 2 ] || fail "--sha256 requires a value."; expected_sha256="$2"; shift 2 ;;
    --install-root) [ "$#" -ge 2 ] || fail "--install-root requires a value."; install_root="$2"; shift 2 ;;
    --rollback) [ "$action" = "install" ] || fail "Choose one lifecycle action."; action="rollback"; shift ;;
    --uninstall) [ "$action" = "install" ] || fail "Choose one lifecycle action."; action="uninstall"; shift ;;
    -h|--help)
      cat <<'EOF'
Usage:
  install.sh --version v0.1.0 [--artifact FILE --sha256 HASH] [--install-root DIR]
  install.sh --rollback [--install-root DIR]
  install.sh --uninstall [--install-root DIR]
EOF
      exit 0
      ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

case "$install_root" in
  /*) ;;
  *) install_root="$PWD/$install_root" ;;
esac
install_root="${install_root%/}"
case "/$install_root/" in
  *"/../"*|*"/./"*) fail "Refusing an install root containing traversal: $install_root" ;;
esac
[ -n "$install_root" ] && [ "$install_root" != "/" ] && [ "$install_root" != "${HOME%/}" ] || fail "Refusing unsafe cxcc install root: $install_root"
[ "${install_root##*/}" = "cxcc" ] || fail "The cxcc install root directory must be named cxcc: $install_root"

is_version() {
  [[ "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  else
    fail "A SHA-256 tool is required."
  fi
}

download_file() {
  local url="$1" destination="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location --output "$destination" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$destination" "$url"
  else
    fail "curl or wget is required to download cxcc."
  fi
}

current_field() {
  local field="$1" current_path="$install_root/current.json"
  [ -f "$current_path" ] || return 0
  sed -n "s/^.*\"${field}\":\"\([^\"]*\)\".*$/\1/p" "$current_path"
}

directory_is_empty() {
  local entry
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || return 1
  done
  return 0
}

validate_root_marker() {
  local require_layout="${1:-0}" marker_path="$install_root/.cxcc-root" relative_path link_path
  [ -f "$marker_path" ] && [ "$(cat "$marker_path")" = "$root_marker_content" ] || fail "Refusing to use an unrecognized cxcc install root: $install_root"
  if [ "$require_layout" = "1" ]; then
    for relative_path in current.json load.ps1 load.sh versions; do
      [ -e "$install_root/$relative_path" ] || fail "Refusing to remove an incomplete cxcc install root: $install_root"
    done
    link_path="$(find "$install_root" -type l -print -quit)"
    if [ -n "$link_path" ]; then
      fail "Refusing to remove a cxcc root containing a symlink: $install_root"
    fi
  fi
}

validate_install_destination() {
  [ ! -L "$install_root" ] || fail "Refusing a symlink cxcc install root: $install_root"
  [ -e "$install_root" ] || return 0
  if [ -f "$install_root/.cxcc-root" ]; then
    validate_root_marker
  else
    directory_is_empty "$install_root" || fail "Refusing to install into a non-empty unrecognized directory: $install_root"
  fi
}

validate_current() {
  local current previous
  [ -f "$install_root/current.json" ] || return 0
  grep -q '"schema":1' "$install_root/current.json" || fail "cxcc current.json has an invalid schema."
  current="$(current_field version)"
  previous="$(current_field previous)"
  is_version "$current" || fail "cxcc current.json contains an invalid version."
  [ -z "$previous" ] || is_version "$previous" || fail "cxcc current.json contains an invalid previous version."
}

write_current() {
  local current="$1" previous="$2" temp_path
  mkdir -p "$install_root"
  temp_path="$install_root/.current.$$.${RANDOM}.tmp"
  if [ -n "$previous" ]; then
    printf '{"schema":1,"version":"%s","previous":"%s"}\n' "$current" "$previous" >"$temp_path"
  else
    printf '{"schema":1,"version":"%s","previous":null}\n' "$current" >"$temp_path"
  fi
  mv -f "$temp_path" "$install_root/current.json"
}

copy_atomic() {
  local source="$1" destination="$2" temp_path
  temp_path="${destination}.$$.${RANDOM}.tmp"
  cp "$source" "$temp_path"
  mv -f "$temp_path" "$destination"
}

ensure_loaders() {
  local version_root="$1" name
  for name in load.ps1 load.sh; do
    [ -f "$install_root/$name" ] || copy_atomic "$version_root/$name" "$install_root/$name"
  done
  chmod 755 "$install_root/load.sh"
}

validate_payload() {
  local root="$1" expected_version="$2" required_file
  for required_file in \
    VERSION load.ps1 load.sh \
    src/powershell/CxCc/CxCc.ps1 \
    src/shell/cxcc.sh src/shell/ai-health.mjs \
    src/bridge/CodexProviderBridge/CodexProviderBridge.csproj \
    templates/profiles.json; do
    [ -f "$root/$required_file" ] || fail "cxcc artifact is missing $required_file."
  done
  [ "$(cat "$root/VERSION")" = "$expected_version" ] || fail "cxcc artifact VERSION does not match $expected_version."
}

assert_tar_safe() {
  local entry normalized details type
  while IFS= read -r entry; do
    normalized="${entry#./}"
    case "$normalized" in
      /*|[A-Za-z]:*|../*|*/../*|*/..) fail "cxcc artifact contains an unsafe path: $entry" ;;
    esac
  done < <(tar -tzf "$1")
  while IFS= read -r details; do
    type="${details%"${details#?}"}"
    case "$type" in
      -|d) ;;
      *) fail "cxcc artifact contains a link or special file: $details" ;;
    esac
  done < <(tar -tvzf "$1")
}

resolve_artifact() {
  if [ -n "$artifact_path" ]; then
    [ -n "$expected_sha256" ] || fail "--sha256 is required with --artifact."
    [ -f "$artifact_path" ] || fail "Artifact does not exist: $artifact_path"
    return
  fi
  [ -z "$expected_sha256" ] || fail "--artifact is required with --sha256."

  local asset_name release_base manifest_path
  asset_name="cxcc-$version-posix.tar.gz"
  release_base="https://github.com/$repository/releases/download/$version"
  download_root="$(mktemp -d)"
  manifest_path="$download_root/SHA256SUMS"
  artifact_path="$download_root/$asset_name"
  download_file "$release_base/SHA256SUMS" "$manifest_path"
  download_file "$release_base/$asset_name" "$artifact_path"
  expected_sha256="$(awk -v asset="$asset_name" '$2 == asset || $2 == ("*" asset) { print tolower($1); exit }' "$manifest_path")"
  [ -n "$expected_sha256" ] || fail "SHA256SUMS does not contain $asset_name."
}

install_version() {
  is_version "$version" || fail "Version must be an exact release tag such as v0.1.0."
  resolve_artifact
  expected_sha256="$(printf '%s' "$expected_sha256" | tr '[:upper:]' '[:lower:]')"
  [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "SHA-256 must contain 64 hexadecimal characters."
  local actual_sha256 versions_root target_path current_version installed_sha
  actual_sha256="$(sha256_file "$artifact_path")"
  [ "$actual_sha256" = "$expected_sha256" ] || fail "cxcc artifact checksum mismatch. Expected $expected_sha256, got $actual_sha256."
  assert_tar_safe "$artifact_path"
  validate_install_destination

  if [ ! -f "$install_root/.cxcc-root" ]; then
    mkdir -p "$install_root"
    marker_temp="$install_root/.cxcc-root.$$.${RANDOM}.tmp"
    printf '%s\n' "$root_marker_content" >"$marker_temp"
    mv -f "$marker_temp" "$install_root/.cxcc-root"
    marker_temp=""
  fi

  validate_current
  current_version="$(current_field version)"
  versions_root="$install_root/versions"
  target_path="$versions_root/$version"
  if [ -d "$target_path" ]; then
    validate_payload "$target_path" "$version"
    [ -f "$target_path/.artifact-sha256" ] || fail "Installed $version has no artifact checksum."
    installed_sha="$(tr -d '\r\n' <"$target_path/.artifact-sha256")"
    [ "$installed_sha" = "$actual_sha256" ] || fail "Installed $version differs from the verified artifact."
  else
    mkdir -p "$versions_root"
    staging_path="$install_root/.staging-$$-${RANDOM}"
    mkdir "$staging_path"
    tar -xzf "$artifact_path" -C "$staging_path"
    validate_payload "$staging_path" "$version"
    printf '%s\n' "$actual_sha256" >"$staging_path/.artifact-sha256"
    mv "$staging_path" "$target_path"
    staging_path=""
  fi

  ensure_loaders "$target_path"
  if [ "$current_version" = "$version" ]; then
    echo "cxcc $version is already installed."
    return
  fi
  write_current "$version" "$current_version"
  echo "cxcc $version installed at $install_root"
}

rollback_version() {
  validate_root_marker 1
  validate_current
  local current previous target_path
  current="$(current_field version)"
  previous="$(current_field previous)"
  [ -n "$previous" ] || fail "No previous cxcc version is available for rollback."
  target_path="$install_root/versions/$previous"
  validate_payload "$target_path" "$previous"
  write_current "$previous" "$current"
  echo "cxcc rolled back to $previous."
}

case "$action" in
  install) install_version ;;
  rollback) rollback_version ;;
  uninstall)
    if [ -e "$install_root" ]; then
      validate_install_destination
      validate_root_marker 1
      rm -rf "$install_root"
    fi
    echo "cxcc uninstalled from $install_root. User state was preserved."
    ;;
esac
