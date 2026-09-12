#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/Sources" "$fixture/Plugins" "$fixture/Tests"
printf '%s\n' 'CUDA and Metal are consumer decisions.' > "$fixture/README.md"
printf '%s\n' 'import Metal' > "$fixture/Tests/BackendTests.swift"
printf '%s\n' 'struct GenericBridge {}' > "$fixture/Sources/Bridge.swift"
"$root/scripts/check-generic-boundary.sh" "$fixture"
printf '%s\n' 'import Metal' > "$fixture/Sources/Bridge.swift"
if "$root/scripts/check-generic-boundary.sh" "$fixture" > /dev/null 2>&1; then
  echo 'Production backend policy was not rejected' >&2
  exit 1
fi
rm "$fixture/Sources/Bridge.swift"
rmdir "$fixture/Sources"
if "$root/scripts/check-generic-boundary.sh" "$fixture" > /dev/null 2>&1; then
  echo 'Missing source directory was not rejected' >&2
  exit 1
fi
echo 'PASS: generic-boundary production rejection, reference allowance and scan failure'
