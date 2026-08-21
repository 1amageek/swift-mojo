#!/bin/zsh

set -euo pipefail

script_root=${0:A:h}
package_root=${1:-}
release_version=${2:-}
tag_name=${3:-$release_version}
candidate_revision=${4:-}

if [[ -z $package_root || $package_root != /* || ! -d $package_root ]]; then
    print -u2 "usage: release-pretag-semver-gate.sh <absolute-package-root> <major.minor.patch> <tag> <full-revision>"
    exit 64
fi
if ! git -C "$package_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print -u2 "error: package root must be a Git worktree"
    exit 64
fi
if [[ $release_version != <->.<->.<-> ]]; then
    print -u2 "error: release version must be a stable major.minor.patch version"
    exit 64
fi
if [[ -z $tag_name || $tag_name == *[[:space:]]* ]] \
    || ! git check-ref-format "refs/tags/$tag_name"; then
    print -u2 "error: tag must be a valid Git tag name without whitespace"
    exit 64
fi
if [[ $candidate_revision == *[^0-9a-fA-F]* \
    || (${#candidate_revision} != 40 && ${#candidate_revision} != 64) ]]; then
    print -u2 "error: candidate revision must be a full 40- or 64-character Git object ID"
    exit 64
fi
if [[ ! -x /usr/bin/python3 ]]; then
    print -u2 "error: /usr/bin/python3 is required to construct the isolated repository URL"
    exit 69
fi
if ! git -C "$package_root" diff --quiet \
    || ! git -C "$package_root" diff --cached --quiet \
    || [[ -n $(git -C "$package_root" ls-files --others --exclude-standard) ]]; then
    print -u2 "error: pre-tag semantic-version source worktree must be clean"
    exit 1
fi

head_revision=$(git -C "$package_root" rev-parse HEAD)
if [[ $head_revision != $candidate_revision ]]; then
    print -u2 "error: candidate revision $candidate_revision does not match package HEAD $head_revision"
    exit 1
fi

gate_root=$(mktemp -d "${TMPDIR%/}/swift-mojo-pretag-semver.XXXXXX")
if [[ ${gate_root:t} != swift-mojo-pretag-semver.* ]]; then
    print -u2 "error: unexpected temporary directory '$gate_root'"
    exit 70
fi

cleanup() {
    if [[ -d $gate_root \
        && ${gate_root:t} == swift-mojo-pretag-semver.* ]]; then
        chmod -R u+w "$gate_root" 2>/dev/null || true
        rm -rf -- "$gate_root"
    fi
}
trap cleanup EXIT INT TERM

isolated_remote="$gate_root/swift-mojo.git"
consumer_root="$gate_root/Consumer"
scratch_root="$gate_root/Scratch"

"$script_root/command-timeout.sh" 60 -- \
    git clone \
    --bare \
    --no-local \
    --no-tags \
    --quiet \
    "$package_root" \
    "$isolated_remote"
git -C "$isolated_remote" \
    -c user.name=swift-mojo \
    -c user.email=swift-mojo@invalid.example \
    tag -a "$tag_name" "$candidate_revision" \
    -m "Isolated pre-tag semantic-version rehearsal"

isolated_remote_url=$(/usr/bin/python3 - "$isolated_remote" <<'PYTHON'
import pathlib
import sys

print(pathlib.Path(sys.argv[1]).resolve().as_uri())
PYTHON
)

mkdir -p "$consumer_root/Sources/Probe"
cat > "$consumer_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftMojoPretagProbe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "$isolated_remote_url",
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
cat > "$consumer_root/Sources/Probe/Probe.swift" <<'SWIFT'
import Mojo

@main
enum Probe {
    static func main() {}
}
SWIFT

"$script_root/command-timeout.sh" 180 -- \
    env -u TOOLCHAINS -u SWIFT_MOJO_EXECUTABLE \
    /usr/bin/xcrun swift build \
    --package-path "$consumer_root" \
    --scratch-path "$scratch_root"

"$script_root/verify-resolved-revision.sh" \
    "$consumer_root/Package.resolved" \
    swift-mojo \
    "$candidate_revision" \
    "$release_version"

"$script_root/command-timeout.sh" 180 -- \
    env -u TOOLCHAINS -u SWIFT_MOJO_EXECUTABLE \
    /usr/bin/xcrun swift package \
    --package-path "$consumer_root" \
    --scratch-path "$scratch_root" \
    --allow-writing-to-package-directory \
    mojo help

print "PASS: isolated tag $tag_name resolves exact version $release_version to $candidate_revision, builds a consumer, and runs the public command plugin"
