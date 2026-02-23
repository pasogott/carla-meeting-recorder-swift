#!/usr/bin/env bash
set -euo pipefail

require_bin() {
  for b in "$@"; do
    command -v "$b" >/dev/null 2>&1 || {
      echo "Missing required tool: $b" >&2
      exit 1
    }
  done
}

require_clean_worktree() {
  require_bin git
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean; commit or stash first." >&2
    exit 1
  fi
}

repo_slug() {
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf "%s\n" "$GITHUB_REPOSITORY"
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    gh repo view --json nameWithOwner -q .nameWithOwner
    return 0
  fi
  git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
}

get_version_and_build() {
  require_bin xcodebuild
  local settings
  settings=$(xcodebuild -project Carla/Carla.xcodeproj -scheme Carla -configuration Release -showBuildSettings)
  local version build
  version=$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*MARKETING_VERSION = //p' | head -n1)
  build=$(printf '%s\n' "$settings" | sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = //p' | head -n1)
  if [[ -z "$version" || -z "$build" ]]; then
    echo "Could not resolve MARKETING_VERSION/CURRENT_PROJECT_VERSION from Xcode build settings." >&2
    exit 1
  fi
  printf '%s\n%s\n' "$version" "$build"
}

next_carla_tag() {
  local base n tag
  base="carla-$(date +%Y.%m.%d)"
  n=0
  while true; do
    tag=$(printf "%s-%02d" "$base" "$n")
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
      n=$((n + 1)); continue
    fi
    if command -v gh >/dev/null 2>&1 && gh release view "$tag" >/dev/null 2>&1; then
      n=$((n + 1)); continue
    fi
    printf "%s\n" "$tag"
    return 0
  done
}
