#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

clone_if_missing() {
  local path="$1"
  local repo="$2"
  local branch="${3:-}"

  if [[ -f "$path/Package.swift" ]]; then
    echo "✓ $path is already available"
    return 0
  fi

  echo "→ Fetching $path"
  rm -rf "$path"
  if [[ -n "$branch" ]]; then
    git clone --depth 1 --recursive --branch "$branch" "$repo" "$path"
  else
    git clone --depth 1 --recursive "$repo" "$path"
  fi

  if [[ ! -f "$path/Package.swift" ]]; then
    echo "::error::$path was fetched but Package.swift is missing"
    exit 1
  fi
}

clone_if_missing "Zsign" "https://github.com/claration/Zsign-Package.git" "package"
clone_if_missing "IDeviceKitten" "https://github.com/CLARATION/IDeviceKit.git"

echo "✓ Local Swift package dependencies are ready"
