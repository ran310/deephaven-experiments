#!/bin/bash
set -euxo pipefail

systemctl stop deephaven-experiments || true

rm -rf /opt/deephaven-experiments/app
mkdir -p /opt/deephaven-experiments/app
