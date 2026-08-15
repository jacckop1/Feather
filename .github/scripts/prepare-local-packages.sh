#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# Keep these in sync with the commits pinned by upstream Feather.
ZSIGN_REPO="https://github.com/khcrysalis/Zsign-Package.git"
ZSIGN_COMMIT="6ffe703df73ef9069adacdbb19d571f11a69a801"
IDEVICE_REPO="https://github.com/khcrysalis/IDeviceKit.git"
IDEVICE_COMMIT="837cf1e14d4875771dd5ee1b754a4c86215c5db3"

checkout_pinned_package() {
  local path="$1"
  local repo="$2"
  local commit="$3"

  # Reuse only when this is already the exact pinned checkout.
  if [[ -d "$path/.git" ]] && [[ -f "$path/Package.swift" ]]; then
    local current
    current="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$current" == "$commit" ]]; then
      echo "✓ $path already pinned at ${commit:0:7}"
      return 0
    fi
  fi

  echo "→ Fetching $path @ ${commit:0:7}"
  rm -rf "$path"
  git clone --filter=blob:none --no-checkout "$repo" "$path"
  if ! git -C "$path" checkout --detach "$commit"; then
    echo "→ Commit was not in the initial clone; fetching it explicitly"
    git -C "$path" fetch --depth 1 origin "$commit"
    git -C "$path" checkout --detach FETCH_HEAD
  fi

  if [[ ! -f "$path/Package.swift" ]]; then
    echo "::error::$path was fetched but Package.swift is missing"
    exit 1
  fi
}

checkout_pinned_package "Zsign" "$ZSIGN_REPO" "$ZSIGN_COMMIT"
checkout_pinned_package "IDeviceKitten" "$IDEVICE_REPO" "$IDEVICE_COMMIT"

# LicensePlist consumes these manual license inputs during the Xcode build.
required_files=(
  "Zsign/Package.swift"
  "Zsign/LICENSE"
  "Zsign/LICENSE_LC"
  "IDeviceKitten/Package.swift"
  "LICENSE_ELLEKIT"
)

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "::error::Required build input is missing: $file"
    exit 1
  fi
  echo "✓ $file"
done

echo "✓ Local Swift package dependencies and license inputs are ready"
