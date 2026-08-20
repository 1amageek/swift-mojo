#!/bin/zsh

set -euo pipefail

search_paths=("$@")
if (( ${#search_paths} == 0 )); then
    search_paths=(Sources Tests)
fi

matches=$(rg -l 'syncShutdownGracefully' "${search_paths[@]}" || true)
if [[ -z "$matches" ]]; then
    print "OK: no synchronous shutdown calls were found"
    exit 0
fi

failed=0
while IFS= read -r file; do
    if rg -q '\bdeinit\b' "$file"; then
        print -u2 "error: synchronous shutdown and deinit coexist in $file"
        failed=1
    fi
done <<< "$matches"

if (( failed != 0 )); then
    exit 1
fi

print "OK: synchronous shutdown calls are not owned by deinit"
