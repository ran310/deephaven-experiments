#!/bin/bash
# CodeDeploy lifecycle: Java 17, venv, heavy pip (deephaven wheel), env file — no systemd here.
set -euxo pipefail

APP_NAME="deephaven-experiments"
APP_DIR="/opt/${APP_NAME}/app"
VENV="/opt/${APP_NAME}/venv"
ENV_FILE="/etc/${APP_NAME}.env"
GUNICORN_PORT=8082

ensure_java17() {
  if command -v java &>/dev/null; then
    if java -version 2>&1 | grep -qE 'version "(1[7-9]|[2-9][0-9])'; then
      return 0
    fi
  fi
  if command -v dnf &>/dev/null; then
    dnf install -y java-17-amazon-corretto-headless
  elif command -v yum &>/dev/null; then
    yum install -y java-17-amazon-corretto-headless
  else
    echo "Install JDK 17+ (Amazon Corretto) on this host." >&2
    exit 1
  fi
}

ensure_java17

if [[ -d /usr/lib/jvm/java-17-amazon-corretto ]]; then
  DEFAULT_JAVA_HOME="/usr/lib/jvm/java-17-amazon-corretto"
else
  DEFAULT_JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
fi

if command -v python3.11 &>/dev/null; then
  PY=python3.11
elif command -v python3 &>/dev/null; then
  PY=python3
else
  echo "python3 not found; install Python 3 on the host." >&2
  exit 1
fi

if [[ ! -d "${VENV}" ]]; then
  "${PY}" -m venv "${VENV}"
fi

export TMPDIR="${TMPDIR:-/var/tmp}"
mkdir -p "$TMPDIR"

echo "Disk space before pip (need a few GiB free on / for Deephaven ~250MB wheel + venv):" >&2
df -h / /tmp "${TMPDIR}" >&2 || df -h >&2
avail_root_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
if [[ "${avail_root_kb:-0}" -lt 2097152 ]]; then
  echo "ERROR: Less than 2 GiB free on /. Enlarge the EBS root volume, clean disk (dnf clean all, journalctl --vacuum-time=3d), or remove old venvs. See deploy/README.md." >&2
  exit 1
fi

"${VENV}/bin/pip" install --upgrade pip
"${VENV}/bin/pip" install --no-cache-dir \
  --default-timeout=600 \
  --retries=15 \
  --resume-retries=25 \
  -r "${APP_DIR}/requirements.txt"

if [[ ! -f "$ENV_FILE" ]]; then
  touch "$ENV_FILE"
fi
if ! grep -q '^JAVA_HOME=' "$ENV_FILE" 2>/dev/null; then
  echo "JAVA_HOME=${DEFAULT_JAVA_HOME}" >> "$ENV_FILE"
fi
if ! grep -q '^FLASK_PORT=' "$ENV_FILE" 2>/dev/null; then
  echo "FLASK_PORT=${GUNICORN_PORT}" >> "$ENV_FILE"
fi
sed -i '/^DEEPHAVEN_HEAP=/d' "$ENV_FILE" 2>/dev/null || true
echo "DEEPHAVEN_HEAP=-Xmx4g" >> "$ENV_FILE"
if ! grep -q '^DEEPHAVEN_PORT=' "$ENV_FILE" 2>/dev/null; then
  echo "DEEPHAVEN_PORT=10000" >> "$ENV_FILE"
fi

echo "AfterInstall complete"
