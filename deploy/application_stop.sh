#!/bin/bash
set -euo pipefail

systemctl stop deephaven-experiments || true
echo "deephaven-experiments stopped (or was not running)"
