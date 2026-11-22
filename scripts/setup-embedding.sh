#!/bin/sh
set -eu
cd "$(dirname "$0")"
root="${AGENT_MEMORY_DATA_DIR:-$HOME/Library/Application Support/AgentMemory}/Embedding"
umask 077
mkdir -p "$root"
uv venv --allow-existing --python 3.12 "$root/runtime"
uv pip install --python "$root/runtime/bin/python" 'fastembed==0.9.1'
install -m 600 embedding-worker.py "$root/worker.py"
HF_HUB_DISABLE_XET=1 "$root/runtime/bin/python" "$root/worker.py" --cache "$root/models" --prepare
