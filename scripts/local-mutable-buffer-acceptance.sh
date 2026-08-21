#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
compiler=${SWIFT_MOJO_EXECUTABLE:-}

if [[ -z $compiler || $compiler != /* || ! -x $compiler ]]; then
    print -u2 "error: SWIFT_MOJO_EXECUTABLE must be an absolute executable path"
    exit 64
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

acceptance_root=$(mktemp -d \
    "${TMPDIR%/}/swift-mojo-mutable-buffer.XXXXXX")
if [[ ${acceptance_root:t} != swift-mojo-mutable-buffer.* ]]; then
    print -u2 "error: unexpected temporary directory '$acceptance_root'"
    exit 70
fi

cleanup() {
    if [[ -d $acceptance_root \
        && ${acceptance_root:t} == swift-mojo-mutable-buffer.* ]]; then
        chmod -R u+w "$acceptance_root" 2>/dev/null || true
        rm -rf -- "$acceptance_root"
    fi
}
trap cleanup EXIT INT TERM

plugin_scratch_root="$acceptance_root/plugin-scratch"

mkdir -p \
    "$acceptance_root/Sources/Application" \
    "$acceptance_root/Mojo/MathModel"

cat > "$acceptance_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MutableBufferAcceptance",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "$root"),
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

cat > "$acceptance_root/Sources/Application/Application.swift" <<'SWIFT'
import Mojo

@mojo(package: "MathModel", function: "scale")
func scale(_ input: [Float], into output: inout [Float]) throws

@main
enum Application {
    static func main() throws {
        var output = [Float](repeating: 0, count: 3)
        try scale([1, 2, 3], into: &output)
        print(output.map { String($0) }.joined(separator: ","))

        var shortOutput = [Float](repeating: 0, count: 2)
        do {
            try scale([1, 2, 3], into: &shortOutput)
            fatalError("Nonzero Mojo status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("status-\(status)")
        }

        do {
            try scale([], into: &output)
            fatalError("Empty input unexpectedly succeeded")
        } catch MojoInvocationError.emptyBorrowedBuffer {
            print("empty-input")
        }

        var emptyOutput: [Float] = []
        do {
            try scale([1], into: &emptyOutput)
            fatalError("Empty output unexpectedly succeeded")
        } catch MojoInvocationError.emptyMutableBuffer {
            print("empty-output")
        }
    }
}
SWIFT

cat > "$acceptance_root/Mojo/MathModel/__init__.mojo" <<'MOJO'
from std.memory import Pointer

def scale(
    input: Pointer[Float32, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float32, MutUntrackedOrigin],
    output_count: UInt64,
) -> Int32:
    if output_count < input_count:
        return 7
    for index in range(Int(input_count)):
        output[unsafe_offset=index] = input[unsafe_offset=index] * 2
    return 0
MOJO

cat > "$acceptance_root/SwiftMojo.json" <<JSON
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
        }
      ]
    }
  }
}
JSON

"$root/scripts/command-timeout.sh" 180 -- \
    env -u TOOLCHAINS /usr/bin/xcrun swift package \
    --package-path "$acceptance_root" \
    --scratch-path "$plugin_scratch_root" \
    --allow-writing-to-package-directory \
    mojo init --target Application

cat > "$acceptance_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MutableBufferAcceptance",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "$root"),
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
    env -u TOOLCHAINS /usr/bin/xcrun swift package \
    --package-path "$acceptance_root" \
    --scratch-path "$plugin_scratch_root" \
    --disable-sandbox \
    --allow-writing-to-package-directory \
    mojo prepare --target Application

scratch_root="$plugin_scratch_root"
"$root/scripts/command-timeout.sh" 180 -- \
    env -u TOOLCHAINS -u SWIFT_MOJO_EXECUTABLE \
    /usr/bin/xcrun swift build \
    --package-path "$acceptance_root" \
    --scratch-path "$scratch_root"

bin_path=$("$root/scripts/command-timeout.sh" 30 -- \
    env -u TOOLCHAINS /usr/bin/xcrun swift build \
    --package-path "$acceptance_root" \
    --scratch-path "$scratch_root" \
    --show-bin-path)
executable="$bin_path/Application"
output=$("$root/scripts/command-timeout.sh" 30 -- "$executable")
if [[ $output != $'2.0,4.0,6.0\nstatus-7\nempty-input\nempty-output' ]]; then
    print -u2 "error: mutable buffer consumer returned '$output'"
    exit 1
fi

symbol_count=$(/usr/bin/nm -gjU "$executable" \
    | /usr/bin/grep -E -c \
        'swift_mojo_.*_(static_abi_version|input_graph_identifier|has_binding|call_f32_buffer_f32_buffer_i32)$')
if [[ $symbol_count != 4 ]]; then
    print -u2 "error: consumer defines $symbol_count bridge symbols, expected 4"
    exit 1
fi
if /usr/bin/otool -L "$executable" | tail -n +2 \
    | /usr/bin/grep -qi mojo; then
    print -u2 "error: consumer has an unexpected Mojo dynamic dependency"
    exit 1
fi

print "PASS: real Mojo mutable buffer compile, static link, scoped mutation, typed status, and empty-buffer failures"
