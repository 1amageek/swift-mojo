#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
compiler=${SWIFT_MOJO_EXECUTABLE:-}
sanitizer=${SWIFT_MOJO_SANITIZE:-}
mojo_asan_runtime=${SWIFT_MOJO_ASAN_RUNTIME:-}

if [[ -z $compiler || $compiler != /* || ! -x $compiler ]]; then
    print -u2 "error: SWIFT_MOJO_EXECUTABLE must be an absolute executable path"
    exit 64
fi
if [[ -n $sanitizer \
    && $sanitizer != swift-address \
    && $sanitizer != mojo-address ]]; then
    print -u2 "error: SWIFT_MOJO_SANITIZE supports 'swift-address' or 'mojo-address'"
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
    "${TMPDIR%/}/swift-mojo-session.XXXXXX")
if [[ ${acceptance_root:t} != swift-mojo-session.* ]]; then
    print -u2 "error: unexpected temporary directory '$acceptance_root'"
    exit 70
fi

cleanup() {
    if [[ -d $acceptance_root \
        && ${acceptance_root:t} == swift-mojo-session.* ]]; then
        chmod -R u+w "$acceptance_root" 2>/dev/null || true
        rm -rf -- "$acceptance_root"
    fi
}
trap cleanup EXIT INT TERM

plugin_scratch_root="$acceptance_root/plugin-scratch"

prepare_compiler=$compiler
swift_sanitizer_arguments=()
if [[ $sanitizer == swift-address ]]; then
    swift_sanitizer_arguments=(--sanitize address)
elif [[ $sanitizer == mojo-address ]]; then
    if [[ -z $mojo_asan_runtime ]] && command -v brew >/dev/null 2>&1; then
        llvm_prefix=$(brew --prefix llvm 2>/dev/null || true)
        llvm_major=$(
            "$llvm_prefix/bin/llvm-config" --version 2>/dev/null \
                | cut -d. -f1
        )
        mojo_asan_runtime="$llvm_prefix/lib/clang/$llvm_major/lib/darwin/libclang_rt.asan_osx_dynamic.dylib"
    fi
    if [[ -z $mojo_asan_runtime \
        || $mojo_asan_runtime != /* \
        || ! -f $mojo_asan_runtime ]]; then
        print -u2 "error: SWIFT_MOJO_ASAN_RUNTIME must name an upstream LLVM macOS ASan dylib"
        exit 64
    fi
    prepare_compiler="$acceptance_root/mojo-address-sanitized"
    export SWIFT_MOJO_UNDERLYING_EXECUTABLE=$compiler
    cat > "$prepare_compiler" <<'ZSH'
#!/bin/zsh

set -euo pipefail

if [[ ${1:-} == build ]]; then
    exec "$SWIFT_MOJO_UNDERLYING_EXECUTABLE" \
        build --sanitize address "${@:2}"
fi
exec "$SWIFT_MOJO_UNDERLYING_EXECUTABLE" "$@"
ZSH
    chmod 700 "$prepare_compiler"
    swift_sanitizer_arguments=(-Xlinker "$mojo_asan_runtime")
fi

mkdir -p \
    "$acceptance_root/Sources/Application" \
    "$acceptance_root/Mojo/SessionModel"

cat > "$acceptance_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SessionAcceptance",
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

@mojo(
    package: "SessionModel",
    function: "create_session",
    shutdown: "shutdown_session"
)
func openSession(
    _ requirements: MojoSessionRequirements
) throws -> MojoSessionOwner

@mojo(
    package: "SessionModel",
    function: "create_buffer",
    shutdown: "destroy_buffer",
    copyFromHost: "copy_from_host",
    copyToHost: "copy_to_host",
    synchronize: "synchronize",
    sessionFactory: "openSession"
)
func makeBuffer(
    _ session: MojoSessionOwner,
    elementCount: UInt64,
    memoryKind: MojoBufferMemoryKind
) throws -> MojoFloat32BufferOwner

@mojo(
    package: "SessionModel",
    function: "scale",
    sessionFactory: "openSession"
)
func scale(
    _ session: MojoSessionOwner,
    _ input: [Float],
    into output: inout [Float]
) throws

@main
enum Application {
    static func main() throws {
        let requirements = MojoSessionRequirements(
            device: .cpu,
            requiredCapabilities: [
                .synchronousInvocation,
                .hostAccessibleMemory,
                .float32,
            ]
        )
        let session = try openSession(requirements)
        print(
            "cpu-\(session.capabilities.ordinal)-\(session.capabilities.availableCapabilities.rawValue)"
        )

        var output = [Float](repeating: 0, count: 3)
        try scale(session, [1, 2, 3], into: &output)
        print(output.map { String($0) }.joined(separator: ","))

        let buffer = try makeBuffer(
            session,
            elementCount: 4,
            memoryKind: .host
        )
        print(
            "buffer-\(buffer.elementCount)-\(buffer.byteCount)-\(buffer.memoryKind.rawValue)"
        )
        try buffer.copy(from: [4, 3, 2, 1])
        var bufferValues = [Float](repeating: 0, count: 4)
        try buffer.copy(into: &bufferValues)
        print(
            "buffer-values-" + bufferValues
                .map { String($0) }
                .joined(separator: ",")
        )
        do {
            try buffer.copy(from: [1])
            fatalError("Mismatched host buffer unexpectedly copied")
        } catch MojoBufferError.elementCountMismatch(
            let expected,
            let actual
        ) {
            print("buffer-count-\(expected)-\(actual)")
        }
        do {
            try buffer.copy(from: [-1, 0, 0, 0])
            fatalError("Nonzero transfer status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("copy-status-\(status)")
        }
        try buffer.copy(from: [-2, 0, 0, 0])
        var failedRead = [Float](repeating: 9, count: 4)
        do {
            try buffer.copy(into: &failedRead)
            fatalError("Nonzero copy-to-host status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("copy-back-status-\(status)")
        }
        do {
            try buffer.copy(from: [-3, 0, 0, 0])
            fatalError("Nonzero synchronization status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("sync-status-\(status)")
        }
        do {
            try session.shutdown()
            fatalError("Session with an active buffer unexpectedly shut down")
        } catch MojoSessionError.activeResources(let count) {
            print("active-resources-\(count)")
        }
        do {
            _ = try makeBuffer(
                session,
                elementCount: 1,
                memoryKind: .device
            )
            fatalError("Unavailable device memory unexpectedly succeeded")
        } catch MojoBufferError.missingCapabilities {
            print("unsupported-memory")
        }
        do {
            _ = try makeBuffer(
                session,
                elementCount: 13,
                memoryKind: .host
            )
            fatalError("Nonzero buffer creation status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("buffer-status-\(status)")
        }
        do {
            _ = try makeBuffer(
                session,
                elementCount: 14,
                memoryKind: .host
            )
            fatalError("Missing buffer handle unexpectedly succeeded")
        } catch MojoInvocationError.resourceCreationReturnedNoHandle(_) {
            print("missing-buffer-handle")
        }
        try buffer.shutdown()
        print(buffer.isShutdown ? "buffer-shutdown" : "buffer-active")
        do {
            try buffer.copy(from: [1, 2, 3, 4])
            fatalError("Shutdown buffer unexpectedly accepted a copy")
        } catch MojoSessionError.resourceShutdown {
            print("copy-after-buffer-shutdown")
        }

        var shortOutput = [Float](repeating: 0, count: 2)
        do {
            try scale(session, [1, 2, 3], into: &shortOutput)
            fatalError("Nonzero session status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("status-\(status)")
        }

        try session.shutdown()
        print(session.isShutdown ? "shutdown" : "active")
        try buffer.shutdown()
        print("buffer-idempotent-after-session")
        do {
            try scale(session, [1], into: &output)
            fatalError("Use after shutdown unexpectedly succeeded")
        } catch MojoSessionError.shutdown {
            print("use-after-shutdown")
        }
        try session.shutdown()
        print("idempotent")

        do {
            _ = try openSession(MojoSessionRequirements(device: .metal))
            fatalError("Unsupported device unexpectedly succeeded")
        } catch MojoInvocationError.sessionRequirementsUnsatisfied {
            print("unsupported-device")
        }

        do {
            _ = try openSession(
                MojoSessionRequirements(device: .cpu, ordinal: 77)
            )
            fatalError("Nonzero creation status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("create-status-\(status)")
        }

        do {
            _ = try openSession(
                MojoSessionRequirements(device: .cpu, ordinal: 99)
            )
            fatalError("Invalid response schema unexpectedly succeeded")
        } catch MojoInvocationError.invalidSessionResponseSchema(
            _,
            _,
            let actual
        ) {
            print("schema-\(actual)")
        }
    }
}
SWIFT

cat > "$acceptance_root/Mojo/SessionModel/__init__.mojo" <<'MOJO'
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer
from std.sys import size_of

struct Session:
    var factor: Float32
    var sync_status: Int32

    def __init__(out self, factor: Float32):
        self.factor = factor
        self.sync_status = 0

def create_session(
    request_schema: UInt32,
    requested_device: UInt32,
    requested_ordinal: UInt32,
    required_capabilities: UInt64,
    session_out: Pointer[
        OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin
    ],
    response_schema_out: Pointer[UInt32, MutUntrackedOrigin],
    actual_device_out: Pointer[UInt32, MutUntrackedOrigin],
    actual_ordinal_out: Pointer[UInt32, MutUntrackedOrigin],
    available_capabilities_out: Pointer[UInt64, MutUntrackedOrigin],
) -> Int32:
    var address = external_call["malloc", UInt](UInt(size_of[Session]()))
    if address == 0:
        return 5
    var session = Pointer[Session, MutUntrackedOrigin](
        unsafe_from_address=Int(address)
    )
    session.unsafe_write(Session(2.0))
    session_out[] = session.unsafe_bitcast[NoneType]()
    response_schema_out[] = 1
    if requested_ordinal == 99:
        response_schema_out[] = 2
    actual_device_out[] = 0
    actual_ordinal_out[] = requested_ordinal
    available_capabilities_out[] = 19
    if requested_ordinal == 77:
        return 23
    return 0

def shutdown_session(
    handle: OpaquePointer[MutUntrackedOrigin],
):
    var session = handle.unsafe_bitcast[Session]()
    session.unsafe_deinit_pointee()
    external_call["free", NoneType](handle)

def create_buffer(
    session: OpaquePointer[MutUntrackedOrigin],
    element_count: UInt64,
    memory_kind: UInt32,
    buffer_out: Pointer[
        OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin
    ],
) -> Int32:
    if memory_kind != 0:
        return 31
    if element_count == 14:
        return 0
    var address = external_call["malloc", UInt](
        UInt(element_count) * UInt(size_of[Float32]())
    )
    if address == 0:
        return 32
    var buffer = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(address)
    )
    buffer_out[] = buffer.unsafe_bitcast[NoneType]()
    if element_count == 13:
        return 33
    return 0

def destroy_buffer(
    session: OpaquePointer[MutUntrackedOrigin],
    buffer: OpaquePointer[MutUntrackedOrigin],
):
    external_call["free", NoneType](buffer)

def copy_from_host(
    session: OpaquePointer[MutUntrackedOrigin],
    buffer: OpaquePointer[MutUntrackedOrigin],
    source: Pointer[Float32, ImmUntrackedOrigin],
    element_count: UInt64,
) -> Int32:
    if source[0] == -1:
        return 34
    var session_state = session.unsafe_bitcast[Session]()
    if source[0] == -3:
        session_state[].sync_status = 36
    var destination = buffer.unsafe_bitcast[Float32]()
    for index in range(Int(element_count)):
        destination[unsafe_offset=index] = source[unsafe_offset=index]
    return 0

def copy_to_host(
    session: OpaquePointer[MutUntrackedOrigin],
    buffer: OpaquePointer[MutUntrackedOrigin],
    destination: Pointer[Float32, MutUntrackedOrigin],
    element_count: UInt64,
) -> Int32:
    var source = buffer.unsafe_bitcast[Float32]()
    if source[0] == -2:
        return 35
    for index in range(Int(element_count)):
        destination[unsafe_offset=index] = source[unsafe_offset=index]
    return 0

def synchronize(
    session: OpaquePointer[MutUntrackedOrigin],
) -> Int32:
    var session_state = session.unsafe_bitcast[Session]()
    var status = session_state[].sync_status
    session_state[].sync_status = 0
    return status

def scale(
    handle: OpaquePointer[MutUntrackedOrigin],
    input: Pointer[Float32, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float32, MutUntrackedOrigin],
    output_count: UInt64,
) -> Int32:
    if output_count < input_count:
        return 7
    var session = handle.unsafe_bitcast[Session]()
    for index in range(Int(input_count)):
        output[unsafe_offset=index] = (
            input[unsafe_offset=index] * session[].factor
        )
    return 0
MOJO

cat > "$acceptance_root/SwiftMojo.json" <<JSON
{
  "schemaVersion": 1,
  "targets": {
    "Application": {
      "compilerVersion": "$compiler_version",
      "mojoPackages": ["SessionModel"],
      "slices": [
        {
          "cpu": "generic",
          "triple": "arm64-apple-macosx15.0"
        },
        {
          "cpu": "x86-64",
          "triple": "x86_64-apple-macosx15.0"
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
    name: "SessionAcceptance",
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

SWIFT_MOJO_EXECUTABLE=$prepare_compiler \
    "$root/scripts/command-timeout.sh" 180 -- \
    env -u TOOLCHAINS /usr/bin/xcrun swift package \
    --package-path "$acceptance_root" \
    --scratch-path "$plugin_scratch_root" \
    --disable-sandbox \
    --allow-writing-to-package-directory \
    mojo prepare --target Application

framework_binary=$(find \
    "$acceptance_root/Generated/Application/SwiftMojo_Application_ABI.xcframework" \
    -type f \
    -path '*/SwiftMojo_Application_ABI.framework/SwiftMojo_Application_ABI' \
    -print)
if [[ $(print -r -- "$framework_binary" | sed '/^$/d' | wc -l | tr -d ' ') != 1 ]]; then
    print -u2 "error: session artifact must contain one universal static framework binary"
    exit 1
fi
architecture_output=$(xcrun lipo -info "$framework_binary")
if [[ $architecture_output != *arm64* || $architecture_output != *x86_64* ]]; then
    print -u2 "error: session static framework does not contain arm64 and x86_64"
    exit 1
fi
if [[ $sanitizer == mojo-address ]]; then
    required_asan_symbols=$(
        /usr/bin/nm -u "$framework_binary" \
            | /usr/bin/awk '/__asan_version_mismatch_check_/ { print $NF }' \
            | /usr/bin/sort -u
    )
    if [[ -z $required_asan_symbols ]]; then
        print -u2 "error: Mojo AddressSanitizer object has no runtime version contract"
        exit 1
    fi
    while IFS= read -r required_symbol; do
        if ! /usr/bin/nm -gU "$mojo_asan_runtime" \
            | /usr/bin/awk -v symbol="$required_symbol" \
                '$NF == symbol { found = 1 } END { exit(found ? 0 : 1) }'; then
            print -u2 "error: Mojo AddressSanitizer runtime does not export $required_symbol"
            exit 1
        fi
    done <<< "$required_asan_symbols"
fi

scratch_root="$acceptance_root/scratch"
"$root/scripts/command-timeout.sh" 180 -- \
    env -u TOOLCHAINS -u SWIFT_MOJO_EXECUTABLE \
    /usr/bin/xcrun swift build \
    "${swift_sanitizer_arguments[@]}" \
    --package-path "$acceptance_root" \
    --scratch-path "$scratch_root"

bin_path=$("$root/scripts/command-timeout.sh" 30 -- \
    env -u TOOLCHAINS /usr/bin/xcrun swift build \
    --package-path "$acceptance_root" \
    --scratch-path "$scratch_root" \
    --show-bin-path)
executable="$bin_path/Application"
output=$("$root/scripts/command-timeout.sh" 30 -- "$executable")
if [[ $output != $'cpu-0-19\n2.0,4.0,6.0\nbuffer-4-16-0\nbuffer-values-4.0,3.0,2.0,1.0\nbuffer-count-4-1\ncopy-status-34\ncopy-back-status-35\nsync-status-36\nactive-resources-1\nunsupported-memory\nbuffer-status-33\nmissing-buffer-handle\nbuffer-shutdown\ncopy-after-buffer-shutdown\nstatus-7\nshutdown\nbuffer-idempotent-after-session\nuse-after-shutdown\nidempotent\nunsupported-device\ncreate-status-23\nschema-2' ]]; then
    print -u2 "error: session consumer returned '$output'"
    exit 1
fi

symbol_count=$(/usr/bin/nm -gjU "$executable" \
    | /usr/bin/grep -E -c \
        'swift_mojo_.*_(static_abi_version|input_graph_identifier|has_binding|create_session_v1|shutdown_session_v1|create_f32_buffer_v1|shutdown_f32_buffer_v1|copy_host_to_f32_buffer_v1|copy_f32_buffer_to_host_v1|call_session_f32_buffer_f32_buffer_i32_v1)$')
if [[ $symbol_count != 10 ]]; then
    print -u2 "error: consumer defines $symbol_count session bridge symbols, expected 10"
    exit 1
fi
if /usr/bin/otool -L "$executable" | tail -n +2 \
    | /usr/bin/grep -qi mojo; then
    print -u2 "error: consumer has an unexpected Mojo dynamic dependency"
    exit 1
fi

if [[ -z $sanitizer ]]; then
cat > "$acceptance_root/Mojo/SessionModel/__init__.mojo" <<'MOJO'
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer, alloc
from std.sys import size_of

struct Session:
    var factor: Float32

    def __init__(out self, factor: Float32):
        self.factor = factor

def create_session(
    request_schema: UInt32,
    requested_device: UInt32,
    requested_ordinal: UInt32,
    required_capabilities: UInt64,
    session_out: Pointer[
        OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin
    ],
    response_schema_out: Pointer[UInt32, MutUntrackedOrigin],
    actual_device_out: Pointer[UInt32, MutUntrackedOrigin],
    actual_ordinal_out: Pointer[UInt32, MutUntrackedOrigin],
    available_capabilities_out: Pointer[UInt64, MutUntrackedOrigin],
) -> Int32:
    var session = alloc[Session](1)
    session.unsafe_write(Session(2.0))
    session_out[] = session.unsafe_bitcast[NoneType]()
    response_schema_out[] = request_schema
    actual_device_out[] = requested_device
    actual_ordinal_out[] = requested_ordinal
    available_capabilities_out[] = required_capabilities
    return 0

def shutdown_session(
    handle: OpaquePointer[MutUntrackedOrigin],
):
    var session = handle.unsafe_bitcast[Session]()
    session.unsafe_deinit_pointee()
    session.unsafe_free()

def create_buffer(
    session: OpaquePointer[MutUntrackedOrigin],
    element_count: UInt64,
    memory_kind: UInt32,
    buffer_out: Pointer[
        OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin
    ],
) -> Int32:
    var address = external_call["malloc", UInt](
        UInt(element_count) * UInt(size_of[Float32]())
    )
    if address == 0:
        return 32
    var buffer = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(address)
    )
    buffer_out[] = buffer.unsafe_bitcast[NoneType]()
    return 0

def destroy_buffer(
    session: OpaquePointer[MutUntrackedOrigin],
    buffer: OpaquePointer[MutUntrackedOrigin],
):
    external_call["free", NoneType](buffer)

def copy_from_host(
    session: OpaquePointer[MutUntrackedOrigin],
    buffer: OpaquePointer[MutUntrackedOrigin],
    source: Pointer[Float32, ImmUntrackedOrigin],
    element_count: UInt64,
) -> Int32:
    return 0

def copy_to_host(
    session: OpaquePointer[MutUntrackedOrigin],
    buffer: OpaquePointer[MutUntrackedOrigin],
    destination: Pointer[Float32, MutUntrackedOrigin],
    element_count: UInt64,
) -> Int32:
    return 0

def synchronize(
    session: OpaquePointer[MutUntrackedOrigin],
) -> Int32:
    return 0

def scale(
    handle: OpaquePointer[MutUntrackedOrigin],
    input: Pointer[Float32, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float32, MutUntrackedOrigin],
    output_count: UInt64,
) -> Int32:
    if output_count < input_count:
        return 7
    var session = handle.unsafe_bitcast[Session]()
    for index in range(Int(input_count)):
        output[unsafe_offset=index] = (
            input[unsafe_offset=index] * session[].factor
        )
    return 0
MOJO

set +e
runtime_dependency_output=$(SWIFT_MOJO_EXECUTABLE=$prepare_compiler \
    "$root/scripts/command-timeout.sh" 180 -- \
    env -u TOOLCHAINS /usr/bin/xcrun swift package \
    --package-path "$acceptance_root" \
    --scratch-path "$plugin_scratch_root" \
    --disable-sandbox \
    --allow-writing-to-package-directory \
    mojo prepare --target Application 2>&1)
runtime_dependency_status=$?
set -e
if [[ $runtime_dependency_status == 0 ]]; then
    print -u2 "error: unsupported Mojo compiler runtime unexpectedly prepared"
    exit 1
fi
if [[ $runtime_dependency_output != *KGEN_CompilerRT_AlignedAlloc* \
    || $runtime_dependency_output != *"does not distribute"* ]]; then
    print -u2 "error: compiler-runtime rejection was not diagnostic: $runtime_dependency_output"
    exit 1
fi
fi

if [[ $sanitizer == swift-address ]]; then
    print "PASS: Swift AddressSanitizer real-Mojo universal owned-session link, lifecycle, and runtime execution"
elif [[ $sanitizer == mojo-address ]]; then
    print "PASS: Mojo AddressSanitizer universal owned-session compile, compatible runtime link, lifecycle, and runtime execution"
else
    print "PASS: real Mojo universal owned-session artifact, exact-count host transfer, capability validation, scoped use, typed failures, exactly-once lifecycle, static link, no Mojo dynamic dependency, and early compiler-runtime rejection"
fi
