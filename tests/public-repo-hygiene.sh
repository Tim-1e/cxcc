#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

INTERNAL_PATHS=(
  "HANDOFF.md"
  "task_plan.md"
  "findings.md"
  "progress.md"
  "docs/baseline-tests.md"
  "docs/migration-hashes.md"
  "docs/migration-inventory.md"
)

for internal_path in "${INTERNAL_PATHS[@]}"; do
  if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$internal_path" >/dev/null 2>&1; then
    echo "Internal project record is tracked: ${internal_path}" >&2
    exit 1
  fi
done

README_CONTENT="$(git -C "$REPO_ROOT" show :README.md)"
if grep -Eq 'Agent 交接|任务计划|现状与决策|执行进度|迁移前基线|复制哈希' <<<"$README_CONTENT"; then
  echo "README exposes internal project-management navigation." >&2
  exit 1
fi

if git -C "$REPO_ROOT" grep --cached -n -I -E '[[:alpha:]]:\\(Users|CodeX_desk)\\' -- . ':(exclude).gitignore'; then
  echo "Tracked public content exposes a local machine path." >&2
  exit 1
fi

echo "Public repository hygiene checks passed."
