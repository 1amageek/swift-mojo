#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
forbidden_pattern='\b(Kuyu|Manas|MLX|Jetson|NVIDIA|CUDA|AGX|Orin|Tegra|Metal|HIP)\b|sm_87|libcuda|\.metal'

search_paths=(
  "$repository_root/README.md"
  "$repository_root/docs"
  "$repository_root/Sources"
  "$repository_root/Tests"
  "$repository_root/Plugins"
  "$repository_root/scripts"
)

if matches="$(
  rg -n -i \
    --glob '!Generated/**' \
    --glob '!check-generic-boundary.sh' \
    "$forbidden_pattern" \
    "${search_paths[@]}"
)"; then
  printf '%s\n' \
    'swift-mojo must not own downstream product or vendor-backend policy:' \
    "$matches" >&2
  exit 1
fi
