#!/usr/bin/env bash

set -euo pipefail

repository_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
forbidden_pattern='\b(Kuyu|Manas|MLX|Jetson|NVIDIA|CUDA|AGX|Orin|Tegra|Metal|HIP)\b|sm_87|libcuda|\.metal'

# Only compiled implementation owns runtime policy. Tests and design references
# intentionally name backends to verify or explain this boundary.
search_paths=("$repository_root/Sources" "$repository_root/Plugins")
set +e
matches="$(rg -n -i --glob '*.swift' --glob '*.c' --glob '*.h' --glob '*.mojo' \
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
