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
plugin_scratch_root="$acceptance_root/plugin-scratch"
mkdir -p \
    "$release_root/Implementation/API" \
    "$release_root/Mojo/MathModel" \
    "$consumer_root/Implementation/API" \
    "$consumer_root/Mojo/MathModel"

cat > "$release_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReleaseAcceptance",
    platforms: [.macOS(.v15)],
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
            ],
            path: "Implementation",
            exclude: ["Excluded.swift"],
            sources: ["API"]
        ),
    ]
)
SWIFT

cat > "$release_root/Implementation/API/Application.swift" <<'SWIFT'
import Mojo

@mojo(package: "MathModel", function: "add")
func add(_ a: Int32, _ b: Int32) -> Int32

@mojo(package: "MathModel", function: "sum")
func sum(_ values: [Float]) throws -> Float

@mojo(package: "MathModel", function: "scale")
func scale(_ input: [Float], into output: inout [Float]) throws

@mojo(
    package: "MathModel",
    function: "create_session",
    shutdown: "shutdown_session"
)
func openSession(
    _ requirements: MojoSessionRequirements
) throws -> MojoSessionOwner

@mojo(
    package: "MathModel",
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
    package: "MathModel",
    function: "scale_session",
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
        print(add(20, 22))
        print(try sum([1, 2, 3, 4]))
        do {
            _ = try sum([])
            fatalError("Empty borrowed buffer unexpectedly succeeded")
        } catch MojoInvocationError.emptyBorrowedBuffer {
            print("invalid-buffer")
        }

        var scaled = [Float](repeating: 0, count: 3)
        try scale([1, 2, 3], into: &scaled)
        print(scaled.map { String($0) }.joined(separator: ","))

        var shortOutput = [Float](repeating: 0, count: 2)
        do {
            try scale([1, 2, 3], into: &shortOutput)
            fatalError("Nonzero Mojo status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("status-\(status)")
        }

        var emptyOutput: [Float] = []
        do {
            try scale([1], into: &emptyOutput)
            fatalError("Empty mutable buffer unexpectedly succeeded")
        } catch MojoInvocationError.emptyMutableBuffer {
            print("empty-output")
        }

        let session = try openSession(
            MojoSessionRequirements(
                device: .cpu,
                requiredCapabilities: [
                    .synchronousInvocation,
                    .hostAccessibleMemory,
                    .float32,
                ]
            )
        )
        print(
            "cpu-\(session.capabilities.ordinal)-\(session.capabilities.availableCapabilities.rawValue)"
        )
        var sessionOutput = [Float](repeating: 0, count: 3)
        try scale(session, [1, 2, 3], into: &sessionOutput)
        print(sessionOutput.map { String($0) }.joined(separator: ","))

        let buffer = try makeBuffer(
            session,
            elementCount: 4,
            memoryKind: .host
        )
        print("buffer-\(buffer.elementCount)-\(buffer.byteCount)")
        try buffer.copy(from: [4, 3, 2, 1])
        var bufferValues = [Float](repeating: 0, count: 4)
        try buffer.copy(into: &bufferValues)
        print(
            "buffer-values-" + bufferValues
                .map { String($0) }
                .joined(separator: ",")
        )
        do {
            try buffer.copy(from: [-1, 0, 0, 0])
            fatalError("Nonzero transfer status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("copy-status-\(status)")
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

        var shortSessionOutput = [Float](repeating: 0, count: 2)
        do {
            try scale(session, [1, 2, 3], into: &shortSessionOutput)
            fatalError("Nonzero session status unexpectedly succeeded")
        } catch MojoInvocationError.invocationFailed(_, let status) {
            print("session-status-\(status)")
        }

        try session.shutdown()
        print(session.isShutdown ? "shutdown" : "active")
        try buffer.shutdown()
        print("buffer-idempotent-after-session")
        do {
            try scale(session, [1], into: &sessionOutput)
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

cat > "$release_root/Implementation/Excluded.swift" <<'SWIFT'
@mojo
func excludedSourceMustNotBeParsed() -> String
SWIFT

cat > "$release_root/Mojo/MathModel/__init__.mojo" <<'MOJO'
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer
from std.sys import size_of

struct Session:
    var factor: Float32

    def __init__(out self, factor: Float32):
        self.factor = factor

def add(a: Int32, b: Int32) -> Int32:
    return a + b

def sum(
    values: Pointer[Float32, ImmUntrackedOrigin],
    count: UInt64,
) -> Float32:
    var result = Float32(0)
    for index in range(Int(count)):
        result += values[unsafe_offset=index]
    return result

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
    session.unsafe_write(Session(3.0))
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
    for index in range(Int(element_count)):
        destination[unsafe_offset=index] = source[unsafe_offset=index]
    return 0

def synchronize(
    session: OpaquePointer[MutUntrackedOrigin],
) -> Int32:
    return 0

def scale_session(
    handle: OpaquePointer[MutUntrackedOrigin],
    input: Pointer[Float32, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float32, MutUntrackedOrigin],
    output_count: UInt64,
) -> Int32:
    if output_count < input_count:
        return 11
    var session = handle.unsafe_bitcast[Session]()
    for index in range(Int(input_count)):
        output[unsafe_offset=index] = (
            input[unsafe_offset=index] * session[].factor
        )
    return 0
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
    --package-path "$release_root" \
    --scratch-path "$plugin_scratch_root" \
    --allow-writing-to-package-directory \
    mojo init --target Application
"$root/scripts/verify-resolved-revision.sh" \
    "$release_root/Package.resolved" \
    swift-mojo \
    "$candidate_revision"

cat > "$release_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReleaseAcceptance",
    platforms: [.macOS(.v15)],
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
            path: "Implementation",
            exclude: ["Excluded.swift"],
            sources: ["API"],
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
    --package-path "$release_root" \
    --scratch-path "$plugin_scratch_root" \
    --disable-sandbox \
    --allow-writing-to-package-directory \
    mojo prepare --target Application
"$root/scripts/command-timeout.sh" 180 -- \
    /usr/bin/xcrun swift package \
    --package-path "$release_root" \
    --scratch-path "$plugin_scratch_root" \
    --allow-writing-to-package-directory \
    mojo release --target Application

framework_binary=$(find \
    "$release_root/Generated/Application/SwiftMojo_Application_ABI.xcframework" \
    -type f \
    -path '*/SwiftMojo_Application_ABI.framework/SwiftMojo_Application_ABI' \
    -print)
if [[ $(print -r -- "$framework_binary" | sed '/^$/d' | wc -l | tr -d ' ') != 1 ]]; then
    print -u2 "error: release artifact must contain one universal static framework binary"
    exit 1
fi
architecture_output=$(xcrun lipo -info "$framework_binary")
if [[ $architecture_output != *arm64* || $architecture_output != *x86_64* ]]; then
    print -u2 "error: universal static framework does not contain arm64 and x86_64"
    exit 1
fi

cat > "$consumer_root/Package.swift" <<SWIFT
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CleanConsumer",
    platforms: [.macOS(.v15)],
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
            path: "Implementation",
            exclude: ["Excluded.swift"],
            sources: ["API"],
            plugins: [
                .plugin(name: "MojoBuildPlugin", package: "swift-mojo"),
            ]
        ),
    ]
)
SWIFT

cp "$release_root/SwiftMojo.json" "$consumer_root/SwiftMojo.json"
cp "$release_root/Implementation/API/Application.swift" \
    "$consumer_root/Implementation/API/Application.swift"
cp "$release_root/Implementation/Excluded.swift" \
    "$consumer_root/Implementation/Excluded.swift"
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
"$root/scripts/verify-resolved-revision.sh" \
    "$consumer_root/Package.resolved" \
    swift-mojo \
    "$candidate_revision"

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
if [[ $output != $'42\n10.0\ninvalid-buffer\n2.0,4.0,6.0\nstatus-7\nempty-output\ncpu-0-19\n3.0,6.0,9.0\nbuffer-4-16\nbuffer-values-4.0,3.0,2.0,1.0\ncopy-status-34\nactive-resources-1\nbuffer-status-33\nmissing-buffer-handle\nsession-status-11\nshutdown\nbuffer-idempotent-after-session\nuse-after-shutdown\nidempotent\nunsupported-device\ncreate-status-23\nschema-2' ]]; then
    print -u2 "error: consumer returned '$output', expected scalar, buffer, owned-session, lifecycle, and typed failure results"
    exit 1
fi

symbol_count=$(/usr/bin/nm -gjU "$executable" \
    | /usr/bin/grep -E -c \
        'swift_mojo_.*_(static_abi_version|input_graph_identifier|has_binding|call_i32_i32_i32|call_f32_buffer_f32|call_f32_buffer_f32_buffer_i32|create_session_v1|shutdown_session_v1|create_f32_buffer_v1|shutdown_f32_buffer_v1|copy_host_to_f32_buffer_v1|copy_f32_buffer_to_host_v1|call_session_f32_buffer_f32_buffer_i32_v1)$')
if [[ $symbol_count != 13 ]]; then
    print -u2 "error: consumer defines $symbol_count bridge symbols, expected 13"
    exit 1
fi
if /usr/bin/otool -L "$executable" | tail -n +2 | /usr/bin/grep -qi mojo; then
    print -u2 "error: consumer has an unexpected Mojo dynamic dependency"
    exit 1
fi

print "PASS: public plugin commands, immutable candidate revision, universal slices, compiler-free relocation, scalar, borrowed-buffer, owned-buffer, and owned-session calls, typed failures, and no Mojo dynamic dependency"
