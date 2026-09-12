#!/usr/bin/env bash

set -euo pipefail

repository_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
forbidden_pattern='(^|[^[:alnum:]_])(Kuyu|Manas|MLX|Jetson|NVIDIA|CUDA|AGX|Orin|Tegra|Metal|HIP)([^[:alnum:]_]|$)|sm_87|libcuda|\.metal'

# Only compiled implementation owns runtime policy. Tests and design references
# intentionally name backends to verify or explain this boundary.
search_paths=("$repository_root/Sources" "$repository_root/Plugins")
for path in "${search_paths[@]}"; do
  if [[ ! -d "$path" ]]; then
    printf '%s\n' "Generic-boundary source directory is missing: $path" >&2
    exit 1
  fi
done
set +e
matches="$(grep -RnEi --include='*.swift' --include='*.c' --include='*.h' --include='*.mojo' \
  "$forbidden_pattern" "${search_paths[@]}")"
status=$?
set -e
if [[ $status == 0 ]]; then
  printf '%s\n' 'swift-mojo must not own downstream product or vendor-backend policy:' "$matches" >&2
  exit 1
elif [[ $status != 1 ]]; then
  printf '%s\n' "Generic-boundary source scan failed with status $status" >&2
  exit "$status"
fi
