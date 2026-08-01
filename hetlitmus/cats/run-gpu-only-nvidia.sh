#!/usr/bin/env bash
# Validate the NVIDIA PTX scoped .cat against the GPU-only oracle (ALL 137 tests).
# The NVIDIA entry point of run-gpu-only.sh, which runs either model.
#
#     bash hetlitmus/cats/run-gpu-only-nvidia.sh
set -u
exec "$(cd "$(dirname "$0")" && pwd)/run-gpu-only.sh" nvidia
