#!/bin/zsh

set -euo pipefail

resolved_file=${1:-}
package_identity=${2:-}
expected_revision=${3:-}
expected_version=${4:-}

if [[ -z $resolved_file || -z $package_identity || -z $expected_revision ]]; then
    print -u2 "usage: verify-resolved-revision.sh <Package.resolved> <identity> <full-revision> [exact-version]"
    exit 64
fi
if [[ -n $expected_version && $expected_version != <->.<->.<-> ]]; then
    print -u2 "error: expected version must be an exact stable semantic version"
    exit 64
fi
if [[ ! -f $resolved_file ]]; then
    print -u2 "error: Package.resolved is missing at '$resolved_file'"
    exit 1
fi
if [[ $expected_revision == *[^0-9a-fA-F]* \
    || (${#expected_revision} != 40 && ${#expected_revision} != 64) ]]; then
    print -u2 "error: expected revision must be a full 40- or 64-character Git object ID"
    exit 64
fi
if [[ ! -x /usr/bin/python3 ]]; then
    print -u2 "error: /usr/bin/python3 is required to inspect Package.resolved"
    exit 69
fi

/usr/bin/python3 - \
    "$resolved_file" \
    "$package_identity" \
    "$expected_revision" \
    "$expected_version" <<'PYTHON'
import json
import pathlib
import sys

resolved_path = pathlib.Path(sys.argv[1])
identity = sys.argv[2]
expected_revision = sys.argv[3]
expected_version = sys.argv[4] or None
document = json.loads(resolved_path.read_text(encoding="utf-8"))
matches = [
    pin
    for pin in document.get("pins", [])
    if pin.get("identity") == identity
]
if len(matches) != 1:
    raise SystemExit(
        f"expected exactly one resolved pin for package identity '{identity}'"
    )
pin = matches[0]
state = pin.get("state")
if not isinstance(state, dict) or not set(state).issubset({"revision", "version"}):
    raise SystemExit(
        f"resolved pin for package identity '{identity}' contains a branch or unknown state"
    )
revision = state.get("revision")
if not isinstance(revision, str):
    raise SystemExit(
        f"resolved pin for package identity '{identity}' has no revision"
    )
version = state.get("version")
if version is not None and (not isinstance(version, str) or not version):
    raise SystemExit(
        f"resolved pin for package identity '{identity}' has an invalid version"
    )
if revision != expected_revision:
    raise SystemExit(
        f"package '{identity}' resolved to {revision}, expected {expected_revision}"
    )
if expected_version is not None and version != expected_version:
    raise SystemExit(
        f"package '{identity}' resolved version {version!r}, expected {expected_version!r}"
    )
PYTHON

if [[ -n $expected_version ]]; then
    print "PASS: package '$package_identity' resolved exact version $expected_version at immutable revision $expected_revision"
else
    print "PASS: package '$package_identity' resolved to immutable revision $expected_revision"
fi
