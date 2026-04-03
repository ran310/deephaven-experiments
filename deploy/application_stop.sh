#!/bin/bash
# Shared CodeDeploy deployment group: ApplicationStop is the *previous* revision's script.
# Must not stop sibling apps. Stop deephaven-experiments in before_install.sh only.
set -euo pipefail
exit 0
