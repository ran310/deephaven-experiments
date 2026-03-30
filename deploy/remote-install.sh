#!/bin/bash
# Run on the EC2 nginx host (via SSM). Args: <s3-bucket> <s3-key>
# Mirrors nfl-quiz deploy: installs under /opt, systemd + nginx, Java 17 for Deephaven.
set -euxo pipefail

BUCKET="$1"
KEY="$2"
APP_NAME="deephaven-experiments"
APP_DIR="/opt/${APP_NAME}/app"
VENV="/opt/${APP_NAME}/venv"
TMP="/tmp/${APP_NAME}-install-$$"
SERVICE_NAME="${APP_NAME}.service"
ENV_FILE="/etc/${APP_NAME}.env"
QUIZ_PATH="/deephaven-live"
GUNICORN_PORT=8082
# Align with aws-infra / nfl-quiz nginx snippet (see deploy/README.md).
PROJECT_NAME="${NFL_QUIZ_PROJECT_NAME:-learn-aws}"
NGINX_CONF="/etc/nginx/conf.d/${PROJECT_NAME}-apps.conf"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

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

mkdir -p "$TMP"
if ! aws s3 cp "s3://${BUCKET}/${KEY}" "${TMP}/app.tgz"; then
  echo "" >&2
  echo "S3 download failed (e.g. 403 Forbidden on HeadObject)." >&2
  echo "The EC2 instance IAM role must allow s3:GetObject (and usually ListBucket for this prefix) on:" >&2
  echo "  s3://${BUCKET}/${KEY}" >&2
  echo "See deploy/README.md: EC2 instance profile must be allowed to read the tarball." >&2
  exit 1
fi
mkdir -p "$APP_DIR"
tar xzf "${TMP}/app.tgz" -C "$APP_DIR"

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

# Pip uses $TMPDIR for wheel download; default /tmp is often tmpfs (~½ RAM on AL2023) and fills on small
# instances → [Errno 28] No space left on device. Use root volume instead.
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
# deephaven_server wheel is ~250MB; flaky PyPI reads show as "incomplete-download" without enough retries.
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
if ! grep -q '^DEEPHAVEN_HEAP=' "$ENV_FILE" 2>/dev/null; then
  echo "DEEPHAVEN_HEAP=-Xmx2g" >> "$ENV_FILE"
fi
if ! grep -q '^DEEPHAVEN_PORT=' "$ENV_FILE" 2>/dev/null; then
  echo "DEEPHAVEN_PORT=10000" >> "$ENV_FILE"
fi

if [[ ! -f /etc/systemd/system/${SERVICE_NAME} ]]; then
  cat >"/etc/systemd/system/${SERVICE_NAME}" <<UNIT
[Unit]
Description=Deephaven experiments (Gunicorn + embedded Deephaven)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
# Deephaven embeds a singleton JVM — use a single Gunicorn worker.
ExecStart=${VENV}/bin/gunicorn --bind 127.0.0.1:${GUNICORN_PORT} --workers 1 --threads 4 --timeout 180 backend.app:app
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
fi

mkdir -p /var/www/app1 /var/www/app2
cat >"$NGINX_CONF" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location = /nfl-quiz {
        return 301 /nfl-quiz/;
    }

    location /nfl-quiz/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix /nfl-quiz;
    }

    location = ${QUIZ_PATH} {
        return 301 ${QUIZ_PATH}/;
    }

    location ${QUIZ_PATH}/ {
        proxy_pass http://127.0.0.1:${GUNICORN_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Prefix ${QUIZ_PATH};
    }

    location /app1/ {
        alias /var/www/app1/;
        index index.html;
    }
    location /app2/ {
        alias /var/www/app2/;
        index index.html;
    }
    location = / {
        default_type text/html;
        return 200 "<html><body><h1>${PROJECT_NAME} nginx</h1><p><a href=\"/nfl-quiz/\">/nfl-quiz/</a> &middot; <a href=\"/deephaven-live/\">/deephaven-live/</a> &middot; <a href=\"/app1/\">/app1/</a> &middot; <a href=\"/app2/\">/app2/</a></p></body></html>";
    }
}
EOF
nginx -t
systemctl reload nginx

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"
systemctl is-active "${SERVICE_NAME}"
