#!/usr/bin/env bash
# ECHO-7 Part A | Human owner: Member A (name/SID pending).
# AI-assisted by OpenAI Codex. Requires Python3+NumPy/Pillow and a normal
# Linux/Ed Verilator5.050, make and C++ toolchain. No hardware is accessed.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "${PYTHON:-python3}" "$SCRIPT_DIR/tools/part_a/run_tests.py" "$@"
