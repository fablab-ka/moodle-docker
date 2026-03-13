#!/bin/bash
set -e

READY_FLAG="/var/www/html/.ready"

if [ "$IS_WORKER" = "false" ]; then
    echo "Stateless Mode: Initializing codebase..."
    
    echo "Restoring core code from /opt/moodle/code/..."
    rsync -rlptD --delete "/opt/moodle/code/" /var/www/html/

    echo "Ensuring correct ownership for /var/www/html..."
    chown -R www-data:www-data /var/www/html

    # Remove old ready flag if it exists
    rm -f "$READY_FLAG"

    echo "Codebase restoration complete."
else
    # Workers wait for the .ready flag
    echo "Worker mode: Waiting for codebase initialization to complete..."
    TIMEOUT=120
    while [ ! -f "$READY_FLAG" ] && [ $TIMEOUT -gt 0 ]; do
        sleep 2
        TIMEOUT=$((TIMEOUT - 1))
    done
    if [ ! -f "$READY_FLAG" ]; then
        echo "ERROR: Codebase not ready after waiting. Is the 'app' container running?"
        exit 1
    fi
    echo "Codebase is ready."
fi
