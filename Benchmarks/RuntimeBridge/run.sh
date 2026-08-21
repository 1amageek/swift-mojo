#!/bin/zsh

set -euo pipefail

root=${0:A:h:h:h}
compiler=${SWIFT_MOJO_EXECUTABLE:-}
buffer_count=${1:-4096}
sample_count=${2:-80}
calls_per_sample=${3:-100}

if [[ -z $compiler || $compiler != /* || ! -x $compiler ]]; then
    print -u2 "error: SWIFT_MOJO_EXECUTABLE must be an absolute executable path"
    exit 64
fi
if [[ ! -x /usr/bin/python3 ]]; then
    print -u2 "error: /usr/bin/python3 is required to inspect MojoArtifact.json"
    exit 69
fi
for value in "$buffer_count" "$sample_count" "$calls_per_sample"; do
    if [[ $value == *[^0-9]* || $value == 0 ]]; then
        print -u2 "error: benchmark arguments must be positive integers"
        exit 64
    fi
done
if [[ $root == *'"'* || $root == *'\\'* || $root == *[[:cntrl:]]* ]]; then
    print -u2 "error: repository path cannot be represented as a Swift string literal"
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
        print -u2 "error: benchmark supports arm64 and x86_64 macOS hosts"
        exit 64
        ;;
esac

benchmark_root=$(mktemp -d "${TMPDIR%/}/swift-mojo-runtime-benchmark.XXXXXX")
if [[ ${benchmark_root:t} != swift-mojo-runtime-benchmark.* ]]; then
    print -u2 "error: unexpected temporary directory '$benchmark_root'"
    exit 70
fi

cleanup() {
    if [[ -d $benchmark_root \
        && ${benchmark_root:t} == swift-mojo-runtime-benchmark.* ]]; then
        chmod -R u+w "$benchmark_root" 2>/dev/null || true
        rm -rf -- "$benchmark_root"
    fi
}
trap cleanup EXIT INT TERM

package_root="$benchmark_root/Package"
scratch_root="$benchmark_root/Scratch"
mkdir -p \
    "$package_root/Implementation" \
    "$package_root/Mojo/BenchmarkModel"
cp "$root/Benchmarks/RuntimeBridge/BenchmarkApplication.swift.template" \
    "$package_root/Implementation/BenchmarkApplication.swift"

cat > "$package_root/Mojo/BenchmarkModel/__init__.mojo" <<'MOJO'
from std.memory import Pointer

def sum(
    values: Pointer[Float32, ImmUntrackedOrigin],
    count: UInt64,
) -> Float32:
    var result = Float32(0)
    for index in range(Int(count)):
        result += values[unsafe_offset=index]
    return result
MOJO

cat > "$package_root/SwiftMojo.json" <<JSON
{
  "schemaVersion": 1,
  "targets": {
    "RuntimeBridgeBenchmark": {
      "compilerVersion": "$compiler_version",
      "mojoPackages": ["BenchmarkModel"],
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

cat > "$package_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeBridgeBenchmark",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "$root"),
    ],
    targets: [
        .executableTarget(
            name: "RuntimeBridgeBenchmark",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
            ],
            path: "Implementation"
        ),
    ]
)
SWIFT

"$root/scripts/command-timeout.sh" 180 -- \
    /usr/bin/xcrun swift package \
    --package-path "$package_root" \
    --scratch-path "$scratch_root" \
    --allow-writing-to-package-directory \
    mojo init --target RuntimeBridgeBenchmark

cat > "$package_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeBridgeBenchmark",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "$root"),
    ],
    targets: [
        .binaryTarget(
            name: "SwiftMojo_RuntimeBridgeBenchmark_ABI",
            path: "Generated/RuntimeBridgeBenchmark/SwiftMojo_RuntimeBridgeBenchmark_ABI.xcframework"
        ),
        .executableTarget(
            name: "RuntimeBridgeBenchmark",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
                "SwiftMojo_RuntimeBridgeBenchmark_ABI",
            ],
            path: "Implementation",
            plugins: [
                .plugin(name: "MojoBuildPlugin", package: "swift-mojo"),
            ]
        ),
    ]
)
SWIFT

SWIFT_MOJO_EXECUTABLE=$compiler \
    "$root/scripts/command-timeout.sh" 300 -- \
    /usr/bin/xcrun swift package \
    --package-path "$package_root" \
    --scratch-path "$scratch_root" \
    --disable-sandbox \
    --allow-writing-to-package-directory \
    mojo prepare --target RuntimeBridgeBenchmark

manifest="$package_root/Generated/RuntimeBridgeBenchmark/MojoArtifact.json"
manifest_values=("${(@f)$(/usr/bin/python3 - "$manifest" <<'PYTHON'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
bindings = manifest.get("bindings", [])
if len(bindings) != 1:
    raise SystemExit("benchmark manifest must contain exactly one binding")
print(manifest["artifactIdentity"]["symbolPrefix"])
print(bindings[0]["bindingID"])
PYTHON
)}")
symbol_prefix=$manifest_values[1]
binding_id=$manifest_values[2]
source="$package_root/Implementation/BenchmarkApplication.swift"
/usr/bin/perl -pi -e \
    "s/__SWIFT_MOJO_DIRECT_CALL__/${symbol_prefix}_call_f32_buffer_f32/g; s/__SWIFT_MOJO_BINDING_ID__/$binding_id/g" \
    "$source"

"$root/scripts/command-timeout.sh" 300 -- \
    /usr/bin/xcrun swift build \
    --package-path "$package_root" \
    --scratch-path "$scratch_root" \
    -c release
binary_path=$("$root/scripts/command-timeout.sh" 30 -- \
    /usr/bin/xcrun swift build \
    --package-path "$package_root" \
    --scratch-path "$scratch_root" \
    -c release \
    --show-bin-path)

print "Swift: $(/usr/bin/xcrun swift --version | /usr/bin/head -n 1)"
print "Mojo: $compiler_version"
"$root/scripts/command-timeout.sh" 180 -- \
    "$binary_path/RuntimeBridgeBenchmark" \
    "$buffer_count" \
    "$sample_count" \
    "$calls_per_sample"
