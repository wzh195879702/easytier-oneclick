#!/usr/bin/env bash
set -Eeuo pipefail

API_URL="${EASYTIER_UPSTREAM_API:-https://api.github.com/repos/EasyTier/EasyTier}"
response="$(curl -fsSL --retry 3 "$API_URL/releases/latest")"
version="$(printf "%s\n" "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$version" ] || { printf "missing latest release tag\n" >&2; exit 1; }

assert_asset() {
  local asset="$1"
  printf "%s\n" "$response" | grep -F "\"name\": \"$asset\"" >/dev/null || {
    printf "missing release asset: %s\n" "$asset" >&2
    exit 1
  }
}

assert_asset "easytier-windows-x86_64-$version.zip"
assert_asset "easytier-windows-arm64-$version.zip"
assert_asset "easytier-windows-i686-$version.zip"
assert_asset "easytier-macos-aarch64-$version.zip"
assert_asset "easytier-macos-x86_64-$version.zip"
assert_asset "easytier-linux-x86_64-$version.zip"
assert_asset "easytier-linux-aarch64-$version.zip"

printf "latest EasyTier release assets verified: %s\n" "$version"
