#!/usr/bin/env bash
# Start backend (Flask + Deephaven) and frontend (Vite) in the background for local dev.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$ROOT/.local"
PID_FILE="$RUN_DIR/dev.pids"

mkdir -p "$RUN_DIR"

if [[ -f "$PID_FILE" ]]; then
  echo "Already running (see $PID_FILE). Run ./stop.sh first."
  exit 1
fi

: >"$PID_FILE"

PYTHON="python3"
if [[ -x "$ROOT/.venv/bin/python" ]]; then
  PYTHON="$ROOT/.venv/bin/python"
elif [[ -x "$ROOT/backend/.venv/bin/python" ]]; then
  PYTHON="$ROOT/backend/.venv/bin/python"
fi

export FLASK_PORT="${FLASK_PORT:-8082}"
FE_PORT="${VITE_PORT:-5175}"

echo "Starting backend → http://127.0.0.1:${FLASK_PORT} (log: $RUN_DIR/backend.log)"
cd "$ROOT"
nohup "$PYTHON" backend/app.py >>"$RUN_DIR/backend.log" 2>&1 &
echo $! >>"$PID_FILE"

echo "Starting frontend → http://127.0.0.1:${FE_PORT} (log: $RUN_DIR/frontend.log)"
cd "$ROOT/frontend"
nohup npm run dev -- --port "$FE_PORT" >>"$RUN_DIR/frontend.log" 2>&1 &
echo $! >>"$PID_FILE"

echo ""
echo "Open UI:  http://127.0.0.1:${FE_PORT}"
echo "API root: http://127.0.0.1:${FLASK_PORT}"
echo "Stop:     ./stop.sh"
