#!/usr/bin/env bash

_cxcc_load() {
  local loader_file loader_root current_path version version_root version_file entrypoint
  if [ -n "${BASH_VERSION:-}" ]; then
    loader_file="${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    loader_file="$(eval 'printf %s "${(%):-%x}"')"
  else
    echo "cxcc supports Bash and Zsh." >&2
    return 1
  fi

  loader_root="$(CDPATH= cd -- "$(dirname -- "$loader_file")" && pwd)" || return 1
  current_path="$loader_root/current.json"
  [ -f "$current_path" ] || { echo "cxcc is not installed: current.json is missing." >&2; return 1; }
  version="$(sed -n 's/^.*"version":"\([^"]*\)".*$/\1/p' "$current_path")"
  printf '%s\n' "$version" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' || {
    echo "cxcc current.json contains an invalid version." >&2
    return 1
  }

  version_root="$loader_root/versions/$version"
  version_file="$version_root/VERSION"
  [ -f "$version_file" ] && [ "$(cat "$version_file")" = "$version" ] || {
    echo "cxcc installed version metadata is invalid: $version" >&2
    return 1
  }
  entrypoint="$version_root/src/shell/cxcc.sh"
  [ -f "$entrypoint" ] || { echo "cxcc shell entrypoint is missing: $entrypoint" >&2; return 1; }

  CXCC_PAYLOAD_ROOT="$version_root"
  # shellcheck source=/dev/null
  . "$entrypoint"
  unset CXCC_PAYLOAD_ROOT
}

_cxcc_load
_cxcc_status=$?
unset -f _cxcc_load
if [ "$_cxcc_status" -ne 0 ]; then
  return "$_cxcc_status" 2>/dev/null || exit "$_cxcc_status"
fi
unset _cxcc_status
