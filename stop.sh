#!/usr/bin/env bash
# Stop local dev processes started by ./start.sh (and clear stuck listeners on dev ports).
set +e

ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$ROOT/.local"
PID_FILE="$RUN_DIR/dev.pids"

FLASK_PORT="${FLASK_PORT:-8082}"
FE_PORT="${VITE_PORT:-5175}"
DH_PORT="${DEEPHAVEN_PORT:-10000}"

stop_pid_file() {
  if [[ ! -f "$PID_FILE" ]]; then
    return 1
  fi
  while read -r pid; do
    [[ -z "${pid:-}" ]] && continue
    if kill -0 "$pid" 2>/dev/null; then
      echo "Stopping PID $pid"
      kill "$pid" 2>/dev/null
    fi
  done <"$PID_FILE"
  rm -f "$PID_FILE"
  return 0
}

stop_pid_file
had_pids=$?

sleep 1

# npm/Vite sometimes leaves a child bound to the port; clean up by port.
for port in "$FLASK_PORT" "$FE_PORT" "$DH_PORT"; do
  if command -v lsof &>/dev/null; then
    pids="$(lsof -ti ":$port" 2>/dev/null || true)"
    if [[ -n "${pids:-}" ]]; then
      echo "Freeing port $port (PIDs: $pids)"
      kill $pids 2>/dev/null
      sleep 1
      pids="$(lsof -ti ":$port" 2>/dev/null || true)"
      [[ -n "${pids:-}" ]] && kill -9 $pids 2>/dev/null
    fi
  fi
done

if [[ $had_pids -ne 0 ]]; then
  echo "No $PID_FILE (stopped listeners on ${FLASK_PORT}, ${FE_PORT}, ${DH_PORT} if any)."
else
  echo "Stopped."
fi
