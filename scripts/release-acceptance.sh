#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
compiler=${SWIFT_MOJO_EXECUTABLE:-}
cli=${SWIFT_MOJO_CLI:-}

if [[ -z $compiler || $compiler != /* || ! -x $compiler ]]; then
    print -u2 "error: SWIFT_MOJO_EXECUTABLE must be an absolute executable path"
    exit 64
fi
if [[ -z $cli || $cli != /* || ! -x $cli ]]; then
    print -u2 "error: SWIFT_MOJO_CLI must be an absolute executable path"
    exit 64
fi
if [[ $root == *'"'* || $root == *'\\'* || $root == *$'\n'* ]]; then
    print -u2 "error: package root cannot be represented as a Swift string literal"
    exit 64
fi

compiler_version=$($compiler --version)
if [[ $compiler_version == *'"'* || $compiler_version == *$'\n'* ]]; then
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

cat > "$release_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReleaseAcceptance",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/1amageek/swift-mojo.git",
            branch: "main"
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

cat > "$release_root/Sources/Application/Application.swift" <<'SWIFT'
import Mojo

@mojo(package: "MathModel", function: "add")
func add(_ a: Int32, _ b: Int32) -> Int32

@main
enum Application {
    static func main() {
        print(add(20, 22))
    }
}
SWIFT

cat > "$release_root/Mojo/MathModel/__init__.mojo" <<'MOJO'
def add(a: Int32, b: Int32) -> Int32:
    return a + b
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

"$root/scripts/swift-test-timeout.sh" 120 -- \
    "$cli" init --package-root "$release_root" --target Application
SWIFT_MOJO_EXECUTABLE=$compiler \
    "$root/scripts/swift-test-timeout.sh" 120 -- \
    "$cli" prepare --package-root "$release_root" --target Application
"$cli" release --package-root "$release_root" --target Application

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
        .package(name: "swift-mojo", path: "$root"),
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

"$root/scripts/swift-test-timeout.sh" 120 -- \
    env -u TOOLCHAINS -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path \
    /usr/bin/xcrun swift build \
    --package-path "$consumer_root" \
    --scratch-path "$scratch_root"

bin_path=$(env -u TOOLCHAINS PATH=$restricted_path /usr/bin/xcrun swift build \
    --package-path "$consumer_root" \
    --scratch-path "$scratch_root" \
    --show-bin-path)
executable="$bin_path/Application"
if [[ ! -x $executable ]]; then
    print -u2 "error: consumer executable was not produced"
    exit 1
fi
output=$(env -u SWIFT_MOJO_EXECUTABLE PATH=$restricted_path "$executable")
if [[ $output != 42 ]]; then
    print -u2 "error: consumer returned '$output', expected '42'"
    exit 1
fi

symbol_count=$(/usr/bin/nm -gjU "$executable" \
    | /usr/bin/grep -E -c \
        'swift_mojo_.*_(static_abi_version|input_graph_identifier|has_binding|call_i32_i32_i32)$')
if [[ $symbol_count != 4 ]]; then
    print -u2 "error: consumer defines $symbol_count bridge symbols, expected 4"
    exit 1
fi
if /usr/bin/otool -L "$executable" | tail -n +2 | /usr/bin/grep -qi mojo; then
    print -u2 "error: consumer has an unexpected Mojo dynamic dependency"
    exit 1
fi

print "PASS: release, universal slices, compiler-free relocation, static link, and runtime returned 42"
