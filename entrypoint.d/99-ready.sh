#!/bin/bash
set -e

READY_FLAG="/var/www/html/.ready"

if [ "$IS_WORKER" = "false" ]; then
    # Step 3: Signal Readiness
    touch "$READY_FLAG"
    echo "Full initialization sequence complete. Signaling readiness to followers."
fi
