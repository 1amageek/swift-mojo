#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <derived-data-path>" >&2
    exit 64
fi

derived_data=$1
intermediates="$derived_data/Build/Intermediates.noindex"

if [[ ! -d "$intermediates" ]]; then
    echo "Xcode build intermediates are missing: $intermediates" >&2
    exit 66
fi

link_file_count=0
leak_count=0

while IFS= read -r link_file; do
    link_file_count=$((link_file_count + 1))
    if /usr/bin/grep -nE \
        '/ExecutableModules/(MojoMacros|swift-mojo)\.o$' \
        "$link_file"; then
        echo "Host executable object leaked into: $link_file" >&2
        leak_count=$((leak_count + 1))
    fi
done < <(
    /usr/bin/find "$intermediates" \
        -type f \
        -name '*.LinkFileList' \
        -print \
        | /usr/bin/sort
)

if [[ $link_file_count -eq 0 ]]; then
    echo "No Xcode LinkFileList files were produced under: $intermediates" >&2
    exit 66
fi

if [[ $leak_count -ne 0 ]]; then
    echo "Found $leak_count host executable link isolation violation(s)" >&2
    exit 1
fi

echo "Verified $link_file_count link file(s); host executable objects are isolated"
