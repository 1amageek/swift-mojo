#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly COMMAND_TIMEOUT="$SCRIPT_DIR/command-timeout.sh"
test_root_candidate="$(
    mktemp -d "${TMPDIR:-/tmp}/swift-mojo-command-plugin-test.XXXXXX"
)"
readonly TEST_ROOT="$(cd "$test_root_candidate" && pwd)"
unset test_root_candidate
readonly FIXTURE_ROOT="$TEST_ROOT/Fixture"
readonly SCRATCH_ROOT="$TEST_ROOT/build"
readonly TARGET_ROOT="$FIXTURE_ROOT/Sources/Model"
readonly BINDING_SOURCE="Sources/Model/Bindings.swift"
readonly TIMEOUT_SECONDS="${SWIFT_MOJO_PLUGIN_TEST_TIMEOUT_SECONDS:-600}"

cleanup() {
    /usr/bin/find "$TEST_ROOT" -type d -exec /bin/chmod u+w {} + \
        2>/dev/null || true
    /bin/rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$TARGET_ROOT"

cat > "$FIXTURE_ROOT/Package.swift" <<'EOF'
// swift-tools-version: 6.2

import Foundation
import PackageDescription

let repositoryRoot = ProcessInfo.processInfo.environment[
    "SWIFT_MOJO_PLUGIN_TEST_REPOSITORY_ROOT"
]!

let package = Package(
    name: "MojoCommandPluginSourceInventoryFixture",
    products: [
        .library(name: "Model", targets: ["Model"]),
    ],
    dependencies: [
        .package(path: repositoryRoot),
    ],
    targets: [
        .target(
            name: "Model",
            path: "Sources/Model",
            exclude: ["Bindings.swift"]
        ),
    ]
)
EOF

cat > "$FIXTURE_ROOT/SwiftMojo.json" <<'EOF'
{
  "schemaVersion": 1,
  "targets": {
    "Model": {
      "compilerVersion": "Mojo 1.0.0 (ed45d567)",
      "mojoPackages": [],
      "slices": [
        {
          "accelerator": "plugin-test",
          "cpu": "generic",
          "triple": "arm64-apple-macosx14.0"
        }
      ]
    }
  }
}
EOF

cat > "$TARGET_ROOT/ModelInventory.swift" <<'EOF'
enum ModelInventory {}
EOF

write_binding_one() {
    cat > "$TARGET_ROOT/Bindings.swift" <<'EOF'
@mojo
func bindingOne(_ lhs: Int32, _ rhs: Int32) -> Int32 {
    return lhs + rhs
}
EOF
}

write_binding_two() {
    cat > "$TARGET_ROOT/Bindings.swift" <<'EOF'
@mojo
func bindingTwo(_ lhs: Int32, _ rhs: Int32) -> Int32 {
    return lhs + rhs
}
EOF
}

write_marker_binding() {
    local name="$1"
    cat > "$TARGET_ROOT/ModelInventory.swift" <<EOF
@mojo
func $name(_ lhs: Int32, _ rhs: Int32) -> Int32 {
    return lhs + rhs
}
EOF
}

write_binding_one
: > "$TEST_ROOT/libRuntime.dylib"

cat > "$TEST_ROOT/fake-mojo" <<'EOF'
#!/bin/sh
set -eu
if [ "${1:-}" = '--version' ]; then
    printf '%s\n' 'Mojo 1.0.0 (ed45d567)'
    exit 0
fi
for argument in "$@"; do
    case "$argument" in
        *.mojo)
            if [ -f "$argument" ]; then
                /bin/cp "$argument" "${PLUGIN_CAPTURE_PATH:?}"
            fi
            ;;
    esac
done
printf '%s\n' 'PLUGIN_COMPILER_SENTINEL' >&2
exit 93
EOF
chmod 0755 "$TEST_ROOT/fake-mojo"

run_swift() {
    "$COMMAND_TIMEOUT" "$TIMEOUT_SECONDS" -- \
        /usr/bin/env \
        "SWIFT_MOJO_PLUGIN_TEST_REPOSITORY_ROOT=$REPOSITORY_ROOT" \
        swift "$@"
}

run_plugin() {
    local capture_path="$1"
    shift
    "$COMMAND_TIMEOUT" "$TIMEOUT_SECONDS" -- \
        /usr/bin/env \
        "PLUGIN_CAPTURE_PATH=$capture_path" \
        "SWIFT_MOJO_EXECUTABLE=$TEST_ROOT/fake-mojo" \
        "SWIFT_MOJO_PLUGIN_TEST_REPOSITORY_ROOT=$REPOSITORY_ROOT" \
        swift package \
        --package-path "$FIXTURE_ROOT" \
        --scratch-path "$SCRATCH_ROOT" \
        --disable-sandbox \
        --allow-writing-to-package-directory \
        mojo "$@"
}

worker_arguments=(
    runtime-worker-prepare
    --target Model
    --output "$TEST_ROOT/Worker.bundle"
    --executable-name plugin-test-worker
    --maximum-frame-payload-bytes 1024
    --target-triple arm64-apple-macosx14.0
    --target-cpu generic
    --target-accelerator plugin-test
    --runtime-library "$TEST_ROOT/libRuntime.dylib"
)

run_swift build \
    --package-path "$FIXTURE_ROOT" \
    --scratch-path "$SCRATCH_ROOT" \
    --target Model \
    --disable-sandbox

expect_compiler_boundary() {
    local capture_path="$1"
    local output_path="$2"
    shift 2
    set +e
    run_plugin "$capture_path" "$@" >"$output_path" 2>&1
    local command_status=$?
    set -e
    if ((command_status == 0)); then
        echo "plugin command unexpectedly passed the fake compiler boundary" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
    if [[ ! -f "$capture_path" ]]; then
        echo "plugin command did not reach the generated Mojo source" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
    if ! /usr/bin/grep -q 'PLUGIN_COMPILER_SENTINEL' "$output_path"; then
        echo "plugin command failed before the expected compiler boundary" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
}

write_marker_binding markerOnly
default_capture="$TEST_ROOT/default.mojo"
expect_compiler_boundary \
    "$default_capture" \
    "$TEST_ROOT/default.log" \
    "${worker_arguments[@]}"

write_marker_binding markerOne
first_capture="$TEST_ROOT/first.mojo"
expect_compiler_boundary \
    "$first_capture" \
    "$TEST_ROOT/first.log" \
    "${worker_arguments[@]}" \
    --binding-source "$BINDING_SOURCE"
if /usr/bin/cmp -s "$default_capture" "$first_capture"; then
    echo "default worker inventory scanned the build-excluded binding source" >&2
    exit 1
fi

write_marker_binding markerTwo
second_capture="$TEST_ROOT/second.mojo"
expect_compiler_boundary \
    "$second_capture" \
    "$TEST_ROOT/second.log" \
    "${worker_arguments[@]}" \
    --binding-source "$BINDING_SOURCE"
if ! /usr/bin/cmp -s "$first_capture" "$second_capture"; then
    echo "compiled marker source changed the explicit worker binding graph" >&2
    exit 1
fi

write_binding_two
third_capture="$TEST_ROOT/third.mojo"
expect_compiler_boundary \
    "$third_capture" \
    "$TEST_ROOT/third.log" \
    "${worker_arguments[@]}" \
    --binding-source "$BINDING_SOURCE"
if /usr/bin/cmp -s "$second_capture" "$third_capture"; then
    echo "explicit binding mutation did not change the worker binding graph" >&2
    exit 1
fi

expect_plugin_failure() {
    local expected="$1"
    shift
    local output_path="$TEST_ROOT/failure-$RANDOM.log"
    set +e
    run_plugin "$TEST_ROOT/unused.mojo" "$@" >"$output_path" 2>&1
    local command_status=$?
    set -e
    if ((command_status == 0)); then
        echo "plugin command unexpectedly passed: $*" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fq -- "$expected" "$output_path"; then
        echo "plugin failure did not contain '$expected': $*" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
}

write_binding_one
cat > "$FIXTURE_ROOT/Outside.swift" <<'EOF'
@mojo func outside(_ lhs: Int32, _ rhs: Int32) -> Int32 { lhs + rhs }
EOF
/bin/ln -s Bindings.swift "$TARGET_ROOT/LinkedBindings.swift"

expect_plugin_failure \
    'outside the selected target directory' \
    "${worker_arguments[@]}" \
    --binding-source Outside.swift
expect_plugin_failure \
    'symbolic link' \
    "${worker_arguments[@]}" \
    --binding-source Sources/Model/LinkedBindings.swift
expect_plugin_failure \
    'duplicate path' \
    "${worker_arguments[@]}" \
    --binding-source "$BINDING_SOURCE" \
    --binding-source "$BINDING_SOURCE"
expect_plugin_failure \
    'Missing value for --binding-source' \
    "${worker_arguments[@]}" \
    --binding-source --format json
expect_plugin_failure \
    '--source and --source-root are owned by MojoCommandPlugin' \
    "${worker_arguments[@]}" \
    --binding-source "$BINDING_SOURCE" \
    --source "$TARGET_ROOT/Bindings.swift"
expect_plugin_failure \
    "--binding-source is not supported by command 'inspect'" \
    inspect --target Model --binding-source "$BINDING_SOURCE"

echo 'Mojo command plugin explicit source inventory paths passed'
