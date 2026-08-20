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
if [[ $root == *'"'* \
    || $root == *'\\'* \
    || $root == *[[:cntrl:]]* ]]; then
    print -u2 "error: package root cannot be represented as a Swift string literal"
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

compiler_version=$("$root/scripts/command-timeout.sh" 30 -- \
    "$compiler" --version)
if [[ $compiler_version == *'"'* \
    || $compiler_version == *'\\'* \
    || $compiler_version == *[[:cntrl:]]* ]]; then
    print -u2 "error: compiler version cannot be represented as JSON"
    exit 64
fi

acceptance_root=$(mktemp -d "${TMPDIR%/}/swift-mojo-release-acceptance.XXXXXX")
if [[ ${acceptance_root:t} != swift-mojo-release-acceptance.* ]]; then
    print -u2 "error: unexpected temporary directory '$acceptance_root'"
    exit 70
fi

cleanup() {
    if [[ -d $acceptance_root && ${acceptance_root:t} == swift-mojo-release-acceptance.* ]]; then
        chmod -R u+w "$acceptance_root" 2>/dev/null || true
        rm -rf -- "$acceptance_root"
    fi
}
trap cleanup EXIT INT TERM

release_root="$acceptance_root/release"
consumer_root="$acceptance_root/consumer"
scratch_root="$acceptance_root/scratch"
mkdir -p \
    "$release_root/Sources/Application" \
    "$release_root/Mojo/MathModel" \
    "$consumer_root/Sources/Application" \
    "$consumer_root/Mojo/MathModel"

cat > "$release_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReleaseAcceptance",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "$candidate_url",
            revision: "$candidate_revision"
        ),
    ],
    targets: [
        .executableTarget(
            name: "Application",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
            ]
        ),
    ]
)
SWIFT

cat > "$release_root/Sources/Application/Application.swift" <<'SWIFT'
import Mojo

@mojo(package: "MathModel", function: "add")
func add(_ a: Int32, _ b: Int32) -> Int32

@mojo(package: "MathModel", function: "sum")
func sum(_ values: [Float]) throws -> Float

@main
enum Application {
    static func main() throws {
        print(add(20, 22))
        print(try sum([1, 2, 3, 4]))
        do {
            _ = try sum([])
            fatalError("Empty borrowed buffer unexpectedly succeeded")
        } catch MojoInvocationError.emptyBorrowedBuffer {
            print("invalid-buffer")
        }
    }
}
SWIFT

cat > "$release_root/Mojo/MathModel/__init__.mojo" <<'MOJO'
from memory import UnsafePointer

def add(a: Int32, b: Int32) -> Int32:
    return a + b

def sum(
    values: UnsafePointer[Float32, ImmutExternalOrigin],
    count: UInt64,
) -> Float32:
    var result = Float32(0)
    for index in range(Int(count)):
        result += values[index]
    return result
MOJO

cat > "$release_root/SwiftMojo.json" <<JSON
{
  "schemaVersion": 1,
  "targets": {
    "Application": {
      "compilerVersion": "$compiler_version",
      "mojoPackages": ["MathModel"],
      "slices": [
        {
          "cpu": "generic",
          "triple": "arm64-apple-macosx14.0"
        },
        {
          "cpu": "x86-64",
          "triple": "x86_64-apple-macosx14.0"
        }
      ]
    }
  }
}
JSON

"$root/scripts/command-timeout.sh" 180 -- \
    /usr/bin/xcrun swift package \
    --allow-writing-to-package-directory \
    --package-path "$release_root" \
    mojo init --target Application

cat > "$release_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReleaseAcceptance",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "$candidate_url",
            revision: "$candidate_revision"
        ),
    ],
    targets: [
        .binaryTarget(
            name: "SwiftMojo_Application_ABI",
            path: "Generated/Application/SwiftMojo_Application_ABI.xcframework"
        ),
        .executableTarget(
            name: "Application",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
                "SwiftMojo_Application_ABI",
            ],
            plugins: [
                .plugin(name: "MojoBuildPlugin", package: "swift-mojo"),
            ]
        ),
    ]
)
SWIFT

SWIFT_MOJO_EXECUTABLE=$compiler \
    "$root/scripts/command-timeout.sh" 180 -- \
    /usr/bin/xcrun swift package \
    --allow-writing-to-package-directory \
    --package-path "$release_root" \
    mojo prepare --target Application
"$root/scripts/command-timeout.sh" 180 -- \
    /usr/bin/xcrun swift package \
    --allow-writing-to-package-directory \
    --package-path "$release_root" \
    mojo release --target Application

archive=$(find \
    "$release_root/Generated/Application/SwiftMojo_Application_ABI.xcframework" \
    -type f -name 'libSwiftMojo_Application_ABI.a' -print)
if [[ $(print -r -- "$archive" | sed '/^$/d' | wc -l | tr -d ' ') != 1 ]]; then
    print -u2 "error: release artifact must contain one universal archive"
    exit 1
fi
architecture_output=$(xcrun lipo -info "$archive")
if [[ $architecture_output != *arm64* || $architecture_output != *x86_64* ]]; then
    print -u2 "error: universal archive does not contain arm64 and x86_64"
    exit 1
fi

cat > "$consumer_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CleanConsumer",
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
            name: "SwiftMojo_Application_ABI",
            path: "Generated/Application/SwiftMojo_Application_ABI.xcframework"
        ),
        .executableTarget(
            name: "Application",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
                "SwiftMojo_Application_ABI",
            ],
            plugins: [
                .plugin(name: "MojoBuildPlugin", package: "swift-mojo"),
            ]
        ),
    ]
)
SWIFT

cp "$release_root/SwiftMojo.json" "$consumer_root/SwiftMojo.json"
cp "$release_root/Sources/Application/Application.swift" \
    "$consumer_root/Sources/Application/Application.swift"
cp "$release_root/Mojo/MathModel/__init__.mojo" \
    "$consumer_root/Mojo/MathModel/__init__.mojo"
cp -R "$release_root/Generated" "$consumer_root/Generated"

restricted_path=/usr/bin:/bin:/usr/sbin:/sbin
if env -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path sh -c 'command -v mojo' \
    >/dev/null 2>&1; then
    print -u2 "error: Mojo unexpectedly exists in the consumer PATH"
    exit 1
fi

"$root/scripts/command-timeout.sh" 120 -- \
    env -u TOOLCHAINS -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path \
    /usr/bin/xcrun swift build \
    --package-path "$consumer_root" \
    --scratch-path "$scratch_root"

bin_path=$("$root/scripts/command-timeout.sh" 30 -- \
    env -u TOOLCHAINS PATH=$restricted_path /usr/bin/xcrun swift build \
    --package-path "$consumer_root" \
    --scratch-path "$scratch_root" \
    --show-bin-path)
executable="$bin_path/Application"
if [[ ! -x $executable ]]; then
    print -u2 "error: consumer executable was not produced"
    exit 1
fi
output=$("$root/scripts/command-timeout.sh" 30 -- \
    env -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path "$executable")
if [[ $output != $'42\n10.0\ninvalid-buffer' ]]; then
    print -u2 "error: consumer returned '$output', expected scalar, buffer, and typed empty-buffer results"
    exit 1
fi

symbol_count=$(/usr/bin/nm -gjU "$executable" \
    | /usr/bin/grep -E -c \
        'swift_mojo_.*_(static_abi_version|input_graph_identifier|has_binding|call_i32_i32_i32|call_f32_buffer_f32)$')
if [[ $symbol_count != 5 ]]; then
    print -u2 "error: consumer defines $symbol_count bridge symbols, expected 5"
    exit 1
fi
if /usr/bin/otool -L "$executable" | tail -n +2 | /usr/bin/grep -qi mojo; then
    print -u2 "error: consumer has an unexpected Mojo dynamic dependency"
    exit 1
fi

"$root/scripts/measure-cold-consumer-build.sh" "$consumer_root"

print "PASS: public plugin commands, immutable candidate revision, universal slices, compiler-free relocation, scalar 42, borrowed buffer 10.0, typed empty-buffer failure, and cold Release measurement"
