#!/bin/zsh

set -euo pipefail

root=${0:A:h:h}
if [[ $root == *'"'* || $root == *'\'* || $root == *[[:cntrl:]]* ]]; then
    print -u2 "error: repository path cannot be represented as a Swift string literal"
    exit 64
fi
scratch=$(mktemp -d "${TMPDIR%/}/swift-mojo-public-boundary.XXXXXX")
cleanup() {
    if [[ -d $scratch && ${scratch:t} == swift-mojo-public-boundary.* ]]; then
        chmod -R u+w "$scratch"
        rm -rf -- "$scratch"
    fi
}
trap cleanup EXIT

cat > "$scratch/Package.swift" <<SWIFT
// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "PublicBoundary", platforms: [.macOS(.v15)],
    dependencies: [.package(path: "$root")],
    targets: [
        .target(name: "RuntimeTyped", dependencies: [.product(name: "MojoRuntime", package: "swift-mojo")]),
        .target(name: "WorkerTyped", dependencies: [.product(name: "MojoRuntimeWorker", package: "swift-mojo")]),
        .target(name: "RuntimeRaw", dependencies: [.product(name: "MojoRuntime", package: "swift-mojo")]),
        .target(name: "WorkerRaw", dependencies: [.product(name: "MojoRuntimeWorker", package: "swift-mojo")]),
    ])
SWIFT
for target in RuntimeTyped WorkerTyped RuntimeRaw WorkerRaw; do
    mkdir -p "$scratch/Sources/$target"
done
cat > "$scratch/Sources/RuntimeTyped/Probe.swift" <<'SWIFT'
import MojoRuntime
public func accept(_ value: MojoRuntimeWorkerBundleVerification) { _ = value.schemaVersion }
SWIFT
cat > "$scratch/Sources/WorkerTyped/Probe.swift" <<'SWIFT'
import MojoRuntimeWorker
public func accept(_ value: MojoRuntimeWorker) { _ = value }
SWIFT

runtime_symbols=(spawn close_file signal_group wait_nohang exit)
worker_symbols=(worker_spawn worker_poll worker_read worker_write signal_group wait_nohang exit)
for target in RuntimeRaw WorkerRaw; do
    if [[ $target == RuntimeRaw ]]; then
        module=MojoRuntime
        symbols=($runtime_symbols)
    else
        module=MojoRuntimeWorker
        symbols=($worker_symbols)
    fi
    {
        print 'import CMojoPOSIXSupport'
        print "import $module"
        print 'public func forbidden() {'
        for symbol in $symbols; do print "    _ = swift_mojo_posix_$symbol"; done
        print '}'
    } > "$scratch/Sources/$target/Probe.swift"
done

for target in RuntimeTyped WorkerTyped RuntimeRaw WorkerRaw; do
    result=0
    "$root/scripts/command-timeout.sh" 300 -- /usr/bin/xcrun swift build \
        --package-path "$scratch" --target "$target" --disable-sandbox \
        > "$scratch/$target.log" 2>&1 || result=$?
    if [[ $target == *Typed ]]; then
        if (( result != 0 )); then cat "$scratch/$target.log"; exit "$result"; fi
    else
        if (( result != 1 )); then
            cat "$scratch/$target.log"
            print -u2 "error: $target must fail by rejecting private POSIX declarations"
            exit 1
        fi
        if [[ $target == RuntimeRaw ]]; then symbols=($runtime_symbols); else symbols=($worker_symbols); fi
        for symbol in $symbols; do
            if ! /usr/bin/grep -Fq "cannot find 'swift_mojo_posix_$symbol' in scope" "$scratch/$target.log"; then
                cat "$scratch/$target.log"
                print -u2 "error: missing compiler rejection for $symbol"
                exit 1
            fi
        done
    fi
    print "PASS: $target compiler status $result"
done
print 'PASS: external products accept typed APIs and reject every private POSIX declaration'
