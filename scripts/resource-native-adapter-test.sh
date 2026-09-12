#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
proof_root=$(mktemp -d "${TMPDIR:-/tmp}/swift-mojo-resource.XXXXXX")
trap 'rm -rf "$proof_root"' EXIT
export SWIFT_MOJO_RESOURCE_PROOF_DIRECTORY="$proof_root"
scripts/swift-test-timeout.sh 120 -- swift test --filter MojoResourceNativeAdapterTests
mojo_compiler=${MOJO_COMPILER:-mojo}
"$mojo_compiler" --version
scripts/command-timeout.sh 120 -- "$mojo_compiler" build --emit shared-lib \
    -I Acceptance/RuntimeWorker/Fixtures/ResourceAdapter -I Acceptance/RuntimeWorker/Mojo \
    "$proof_root/bridge.mojo" -o "$proof_root/bridge.dylib"
resource_symbol=$(cat "$proof_root/symbol")
resource_prefix=${resource_symbol%_invoke_resource_*}
factory_id=$(sed -n '/_create_session_v1(/,/return -1/p' "$proof_root/bridge.mojo" | sed -n 's/.*if binding_id == \([0-9]*\):/\1/p')
clang -Wall -Wextra -Werror -I "$proof_root" \
    -DINVOKE="$resource_symbol" -DCREATE="${resource_prefix}_create_session_v1" \
    -DDESTROY="${resource_prefix}_shutdown_session_v1" -DFACTORY="${factory_id}ULL" \
    Acceptance/RuntimeWorker/Fixtures/ResourceAdapter/Consumer.c "$proof_root/bridge.dylib" \
    -Wl,-rpath,"$proof_root" -o "$proof_root/consumer"
scripts/command-timeout.sh 30 -- "$proof_root/consumer"
