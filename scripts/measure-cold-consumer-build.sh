#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
package_root=${1:-}
timeout_seconds=${SWIFT_MOJO_COLD_BUILD_TIMEOUT_SECONDS:-600}

if [[ -z $package_root || $package_root != /* || ! -f $package_root/Package.swift ]]; then
    print -u2 "usage: measure-cold-consumer-build.sh /absolute/path/to/consumer-package"
    exit 64
fi
if [[ $timeout_seconds != <-> \
    || $timeout_seconds -le 0 \
    || $timeout_seconds -gt 900 ]]; then
    print -u2 "error: SWIFT_MOJO_COLD_BUILD_TIMEOUT_SECONDS must be from 1 through 900"
    exit 64
fi

scratch_root=$(mktemp -d "${TMPDIR%/}/swift-mojo-cold-build.XXXXXX")
if [[ ${scratch_root:t} != swift-mojo-cold-build.* ]]; then
    print -u2 "error: unexpected temporary directory '$scratch_root'"
    exit 70
fi

cleanup() {
    if [[ -d $scratch_root && ${scratch_root:t} == swift-mojo-cold-build.* ]]; then
        chmod -R u+w "$scratch_root" 2>/dev/null || true
        rm -rf -- "$scratch_root"
    fi
}
trap cleanup EXIT INT TERM

restricted_path=/usr/bin:/bin:/usr/sbin:/sbin
if env -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path sh -c 'command -v mojo' \
    >/dev/null 2>&1; then
    print -u2 "error: Mojo unexpectedly exists in the consumer PATH"
    exit 1
fi
start_seconds=$SECONDS
"$root/scripts/command-timeout.sh" "$timeout_seconds" -- \
    env -u TOOLCHAINS -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path \
    /usr/bin/xcrun swift build \
    --configuration release \
    --package-path "$package_root" \
    --scratch-path "$scratch_root"
elapsed_seconds=$((SECONDS - start_seconds))

print "cold_release_build_seconds=$elapsed_seconds"
print "package_root=$package_root"
print "scratch_policy=fresh_per_run"
print "mojo_compiler_available=false"
