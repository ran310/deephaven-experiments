#!/bin/bash
set -euxo pipefail

APP_NAME="deephaven-experiments"
APP_DIR="/opt/${APP_NAME}/app"
VENV="/opt/${APP_NAME}/venv"
ENV_FILE="/etc/${APP_NAME}.env"
GUNICORN_PORT=8082
SERVICE_NAME="${APP_NAME}.service"

cat >"/etc/systemd/system/${SERVICE_NAME}" <<UNIT
[Unit]
Description=Deephaven experiments (Gunicorn + embedded Deephaven)
After=network.target
ConditionPathExists=${VENV}/bin/gunicorn

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${VENV}/bin/gunicorn --bind 127.0.0.1:${GUNICORN_PORT} --workers 1 --threads 4 --timeout 180 backend.app:app
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"
systemctl is-active "${SERVICE_NAME}"
