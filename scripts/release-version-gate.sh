#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
release_version=${1:-}
tag_name=${2:-$release_version}
candidate_url=${SWIFT_MOJO_CANDIDATE_URL:-}

if [[ $release_version != <->.<->.<-> ]]; then
    print -u2 "usage: release-version-gate.sh <major.minor.patch> [tag]"
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
version_source="$root/Sources/MojoCommandCore/SwiftMojoVersion.swift"
source_version=$(/usr/bin/sed -nE \
    's/^[[:space:]]*package static let current = "([^"]+)"[[:space:]]*$/\1/p' \
    "$version_source")
if [[ $source_version != $release_version ]]; then
    print -u2 "error: source version is '$source_version', expected '$release_version'"
    exit 1
fi
if [[ $source_version == *-dev* ]]; then
    print -u2 "error: release version cannot contain '-dev'"
    exit 1
fi

if [[ $(git -C "$root" branch --show-current) != main ]]; then
    print -u2 "error: releases must be cut from main"
    exit 1
fi
if ! git -C "$root" diff --quiet \
    || ! git -C "$root" diff --cached --quiet \
    || [[ -n $(git -C "$root" ls-files --others --exclude-standard) ]]; then
    print -u2 "error: release candidate worktree must be clean"
    exit 1
fi

head_commit=$(git -C "$root" rev-parse HEAD)
origin_commit=$(git -C "$root" rev-parse origin/main)
if [[ $head_commit != $origin_commit ]]; then
    print -u2 "error: HEAD $head_commit does not match origin/main $origin_commit"
    exit 1
fi
if ! git ls-remote "$candidate_url" \
    | /usr/bin/awk -v candidate="$head_commit" \
        '$1 == candidate { found = 1 } END { exit(found ? 0 : 1) }'; then
    print -u2 "error: candidate revision $head_commit is not advertised by the remote"
    exit 1
fi
if git -C "$root" show-ref --verify --quiet "refs/tags/$tag_name"; then
    print -u2 "error: tag '$tag_name' already exists"
    exit 1
fi

gate_scratch=$(mktemp -d "${TMPDIR%/}/swift-mojo-version-gate.XXXXXX")
if [[ ${gate_scratch:t} != swift-mojo-version-gate.* ]]; then
    print -u2 "error: unexpected temporary directory '$gate_scratch'"
    exit 70
fi

cleanup() {
    if [[ -d $gate_scratch && ${gate_scratch:t} == swift-mojo-version-gate.* ]]; then
        chmod -R u+w "$gate_scratch" 2>/dev/null || true
        rm -rf -- "$gate_scratch"
    fi
}
trap cleanup EXIT INT TERM

gate_package="$gate_scratch/Package"
gate_build="$gate_scratch/Build"
mkdir -p \
    "$gate_package/Sources" \
    "$gate_package/Generated"
/usr/bin/ditto \
    "$root/Sources/MojoBuildPluginIntegrationFixture" \
    "$gate_package/Sources/MojoBuildPluginIntegrationFixture"
/usr/bin/ditto \
    "$root/Generated/MojoBuildPluginIntegrationFixture" \
    "$gate_package/Generated/MojoBuildPluginIntegrationFixture"
/bin/cp "$root/SwiftMojo.json" "$gate_package/SwiftMojo.json"
cat > "$gate_package/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftMojoReleaseProbe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "$candidate_url",
            revision: "$head_commit"
        ),
    ],
    targets: [
        .binaryTarget(
            name: "SwiftMojo_MojoBuildPluginIntegrationFixture_ABI",
            path: "Generated/MojoBuildPluginIntegrationFixture/SwiftMojo_MojoBuildPluginIntegrationFixture_ABI.xcframework"
        ),
        .target(
            name: "MojoBuildPluginIntegrationFixture",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
                "SwiftMojo_MojoBuildPluginIntegrationFixture_ABI",
            ],
            plugins: [
                .plugin(
                    name: "MojoBuildPlugin",
                    package: "swift-mojo"
                ),
            ]
        ),
    ]
)
SWIFT

version_json=$("$root/scripts/command-timeout.sh" 180 -- \
    /usr/bin/xcrun swift package \
    --package-path "$gate_package" \
    --scratch-path "$gate_build" \
    --allow-writing-to-package-directory \
    mojo version --format json \
    | /usr/bin/tail -n 1)
expected_version_json="{\"command\":\"version\",\"message\":\"$release_version\",\"success\":true}"
if [[ $version_json != $expected_version_json ]]; then
    print -u2 "error: candidate command reported '$version_json', expected '$expected_version_json'"
    exit 1
fi
"$root/scripts/verify-resolved-revision.sh" \
    "$gate_package/Package.resolved" \
    swift-mojo \
    "$head_commit"

"$root/scripts/command-timeout.sh" 180 -- \
    /usr/bin/xcrun swift package \
    --package-path "$gate_package" \
    --scratch-path "$gate_build" \
    --allow-writing-to-package-directory \
    mojo release --target MojoBuildPluginIntegrationFixture

print "PASS: candidate command version $release_version is clean, pushed, release-verified, and ready for tag $tag_name"
