#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
release_version=${1:-}
tag_name=${2:-$release_version}
candidate_url=${SWIFT_MOJO_CANDIDATE_URL:-}

if [[ $release_version != <->.<->.<-> ]]; then
    print -u2 "usage: release-tag-gate.sh <major.minor.patch> [tag]"
    exit 64
fi
if [[ -z $tag_name || $tag_name == *[[:space:]]* ]]; then
    print -u2 "error: tag must be a non-empty name without whitespace"
    exit 64
fi
if [[ $candidate_url != https://* \
    && $candidate_url != http://* \
    && $candidate_url != ssh://* \
    && $candidate_url != git://* ]]; then
    print -u2 "error: SWIFT_MOJO_CANDIDATE_URL must be a remote package URL"
    exit 64
fi
if [[ $candidate_url == *'"'* \
    || $candidate_url == *'\\'* \
    || $candidate_url == *[[:cntrl:]]* ]]; then
    print -u2 "error: candidate URL cannot be represented as a Swift string literal"
    exit 64
fi
if ! git -C "$root" show-ref --verify --quiet "refs/tags/$tag_name"; then
    print -u2 "error: local tag '$tag_name' does not exist"
    exit 1
fi

tag_commit=$(git -C "$root" rev-list -1 "$tag_name")
origin_commit=$(git -C "$root" rev-parse origin/main)
if [[ $tag_commit != $origin_commit ]]; then
    print -u2 "error: tag $tag_name resolves to $tag_commit, origin/main is $origin_commit"
    exit 1
fi
if ! git ls-remote "$candidate_url" \
    "refs/tags/$tag_name" "refs/tags/$tag_name^{}" \
    | /usr/bin/awk -v candidate="$tag_commit" \
        '$1 == candidate { found = 1 } END { exit(found ? 0 : 1) }'; then
    print -u2 "error: remote tag '$tag_name' does not resolve to $tag_commit"
    exit 1
fi

gate_root=$(mktemp -d "${TMPDIR%/}/swift-mojo-tag-gate.XXXXXX")
if [[ ${gate_root:t} != swift-mojo-tag-gate.* ]]; then
    print -u2 "error: unexpected temporary directory '$gate_root'"
    exit 70
fi

cleanup() {
    if [[ -d $gate_root && ${gate_root:t} == swift-mojo-tag-gate.* ]]; then
        chmod -R u+w "$gate_root" 2>/dev/null || true
        rm -rf -- "$gate_root"
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$gate_root/Package/Sources/Probe"
cat > "$gate_root/Package/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftMojoTagProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "$candidate_url",
            exact: "$release_version"
        ),
    ],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
            ]
        ),
    ]
)
SWIFT
cat > "$gate_root/Package/Sources/Probe/Probe.swift" <<'SWIFT'
import Mojo

@main
enum Probe {
    static func main() {}
}
SWIFT

version_json=$("$root/scripts/command-timeout.sh" 180 -- \
    /usr/bin/xcrun swift package \
    --package-path "$gate_root/Package" \
    --scratch-path "$gate_root/Scratch" \
    --allow-writing-to-package-directory \
    mojo version --format json \
    | /usr/bin/tail -n 1)
expected_version_json="{\"command\":\"version\",\"message\":\"$release_version\",\"success\":true}"
if [[ $version_json != $expected_version_json ]]; then
    print -u2 "error: exact-tag command reported '$version_json', expected '$expected_version_json'"
    exit 1
fi

print "PASS: exact version $release_version resolves tag $tag_name at origin/main and runs the public command plugin"
