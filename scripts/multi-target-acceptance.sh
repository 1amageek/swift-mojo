#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
compiler=${SWIFT_MOJO_EXECUTABLE:-}
candidate_url=${SWIFT_MOJO_CANDIDATE_URL:-}
candidate_revision=$(git -C "$root" rev-parse HEAD)

if [[ -z $compiler || $compiler != /* || ! -x $compiler ]]; then
    print -u2 "error: SWIFT_MOJO_EXECUTABLE must be an absolute executable path"
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
if ! git ls-remote "$candidate_url" \
    | /usr/bin/awk -v candidate="$candidate_revision" \
        '$1 == candidate { found = 1 } END { exit(found ? 0 : 1) }'; then
    print -u2 "error: candidate revision $candidate_revision is not advertised by $candidate_url"
    exit 1
fi
if [[ $root == *'"'* \
    || $root == *'\\'* \
    || $root == *[[:cntrl:]]* ]]; then
    print -u2 "error: package root cannot be represented as a Swift string literal"
    exit 64
fi

compiler_version=$("$root/scripts/command-timeout.sh" 30 -- \
    "$compiler" --version)
if [[ $compiler_version == *'"'* \
    || $compiler_version == *'\\'* \
    || $compiler_version == *[[:cntrl:]]* ]]; then
    print -u2 "error: compiler version cannot be represented as JSON"
    exit 64
fi

case $(uname -m) in
    arm64)
        target_triple=arm64-apple-macosx14.0
        target_cpu=generic
        ;;
    x86_64)
        target_triple=x86_64-apple-macosx14.0
        target_cpu=x86-64
        ;;
    *)
        print -u2 "error: this acceptance supports arm64 and x86_64 macOS hosts"
        exit 64
        ;;
esac

acceptance_root=$(mktemp -d "${TMPDIR%/}/swift-mojo-multi-target.XXXXXX")
if [[ ${acceptance_root:t} != swift-mojo-multi-target.* ]]; then
    print -u2 "error: unexpected temporary directory '$acceptance_root'"
    exit 70
fi

cleanup() {
    if [[ -d $acceptance_root && ${acceptance_root:t} == swift-mojo-multi-target.* ]]; then
        chmod -R u+w "$acceptance_root" 2>/dev/null || true
        rm -rf -- "$acceptance_root"
    fi
}
trap cleanup EXIT INT TERM

mkdir -p \
    "$acceptance_root/Sources/ModelA" \
    "$acceptance_root/Sources/ModelB" \
    "$acceptance_root/Sources/Application" \
    "$acceptance_root/Mojo/MathModel"

cat > "$acceptance_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MultiTargetAcceptance",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "swift-mojo",
            url: "$candidate_url",
            revision: "$candidate_revision"
        ),
    ],
    targets: [
        .target(
            name: "ModelA",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
            ]
        ),
        .target(
            name: "ModelB",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
            ]
        ),
        .executableTarget(
            name: "Application",
            dependencies: ["ModelA", "ModelB"]
        ),
    ]
)
SWIFT

cat > "$acceptance_root/Sources/ModelA/ModelA.swift" <<'SWIFT'
import Mojo

@mojo(package: "MathModel", function: "add")
public func modelAAdd(_ a: Int32, _ b: Int32) -> Int32
SWIFT

cat > "$acceptance_root/Sources/ModelB/ModelB.swift" <<'SWIFT'
import Mojo

@mojo(package: "MathModel", function: "add")
public func modelBAdd(_ a: Int32, _ b: Int32) -> Int32
SWIFT

cat > "$acceptance_root/Sources/Application/Application.swift" <<'SWIFT'
import ModelA
import ModelB

@main
enum Application {
    static func main() {
        print(modelAAdd(20, 22))
        print(modelBAdd(19, 23))
    }
}
SWIFT

cat > "$acceptance_root/Mojo/MathModel/__init__.mojo" <<'MOJO'
def add(a: Int32, b: Int32) -> Int32:
    return a + b
MOJO

cat > "$acceptance_root/SwiftMojo.json" <<JSON
{
  "schemaVersion": 1,
  "targets": {
    "ModelA": {
      "compilerVersion": "$compiler_version",
      "mojoPackages": ["MathModel"],
      "slices": [
        {
          "cpu": "$target_cpu",
          "triple": "$target_triple"
        }
      ]
    },
    "ModelB": {
      "compilerVersion": "$compiler_version",
      "mojoPackages": ["MathModel"],
      "slices": [
        {
          "cpu": "$target_cpu",
          "triple": "$target_triple"
        }
      ]
    }
  }
}
JSON

for target in ModelA ModelB; do
    "$root/scripts/command-timeout.sh" 180 -- \
        /usr/bin/xcrun swift package \
        --package-path "$acceptance_root" \
        --allow-writing-to-package-directory \
        mojo init --target "$target"
done

cat > "$acceptance_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MultiTargetAcceptance",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            name: "swift-mojo",
            url: "$candidate_url",
            revision: "$candidate_revision"
        ),
    ],
    targets: [
        .binaryTarget(
            name: "SwiftMojo_ModelA_ABI",
            path: "Generated/ModelA/SwiftMojo_ModelA_ABI.xcframework"
        ),
        .binaryTarget(
            name: "SwiftMojo_ModelB_ABI",
            path: "Generated/ModelB/SwiftMojo_ModelB_ABI.xcframework"
        ),
        .target(
            name: "ModelA",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
                "SwiftMojo_ModelA_ABI",
            ],
            plugins: [
                .plugin(name: "MojoBuildPlugin", package: "swift-mojo"),
            ]
        ),
        .target(
            name: "ModelB",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
                "SwiftMojo_ModelB_ABI",
            ],
            plugins: [
                .plugin(name: "MojoBuildPlugin", package: "swift-mojo"),
            ]
        ),
        .executableTarget(
            name: "Application",
            dependencies: ["ModelA", "ModelB"]
        ),
    ]
)
SWIFT

for target in ModelA ModelB; do
    SWIFT_MOJO_EXECUTABLE=$compiler \
        "$root/scripts/command-timeout.sh" 180 -- \
        /usr/bin/xcrun swift package \
        --package-path "$acceptance_root" \
        --allow-writing-to-package-directory \
        mojo prepare --target "$target"
done

restricted_path=/usr/bin:/bin:/usr/sbin:/sbin
scratch_root="$acceptance_root/scratch"
"$root/scripts/command-timeout.sh" 180 -- \
    env -u TOOLCHAINS -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path \
    /usr/bin/xcrun swift build \
    --package-path "$acceptance_root" \
    --scratch-path "$scratch_root"

bin_path=$("$root/scripts/command-timeout.sh" 30 -- \
    env -u TOOLCHAINS PATH=$restricted_path /usr/bin/xcrun swift build \
    --package-path "$acceptance_root" \
    --scratch-path "$scratch_root" \
    --show-bin-path)
executable="$bin_path/Application"
output=$("$root/scripts/command-timeout.sh" 30 -- \
    env -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path "$executable")
if [[ $output != $'42\n42' ]]; then
    print -u2 "error: multi-target consumer returned '$output'"
    exit 1
fi

symbol_count=$(/usr/bin/nm -gjU "$executable" \
    | /usr/bin/grep -E -c \
        'swift_mojo_.*_(static_abi_version|input_graph_identifier|has_binding|call_i32_i32_i32)$')
if [[ $symbol_count != 8 ]]; then
    print -u2 "error: multi-target consumer defines $symbol_count bridge symbols, expected 8"
    exit 1
fi
prefix_count=$(/usr/bin/nm -gjU "$executable" \
    | /usr/bin/grep -E 'swift_mojo_.*_static_abi_version$' \
    | /usr/bin/sed -E 's/_static_abi_version$//' \
    | /usr/bin/sort -u \
    | /usr/bin/wc -l \
    | tr -d ' ')
if [[ $prefix_count != 2 ]]; then
    print -u2 "error: multi-target consumer has $prefix_count symbol prefixes, expected 2"
    exit 1
fi
if /usr/bin/otool -L "$executable" | tail -n +2 | /usr/bin/grep -qi mojo; then
    print -u2 "error: multi-target consumer has an unexpected Mojo dynamic dependency"
    exit 1
fi

print "PASS: immutable candidate public commands prepared two Mojo-enabled targets, linked without symbol collisions, and both returned 42"
