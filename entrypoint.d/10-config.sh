#!/bin/bash
set -e

if [ "$IS_WORKER" = "false" ]; then
    echo "Syncing Moodle source code from image to volume..."
    
    # Prepare exclude arguments for rsync
    # Default excludes to prevent overwriting persistent plugins/themes if mounted
    EXCLUDE_ARGS=""
    for item in ${MOODLE_DOCKER_SYNC_EXCLUDE:-}; do
        EXCLUDE_ARGS="$EXCLUDE_ARGS --exclude=$item"
    done

    # Sync code. --delete ensures we don't have lingering old core files.
    # Users should use volumes + MOODLE_DOCKER_SYNC_EXCLUDE to persist custom plugins.
    rsync -rlptD --delete $EXCLUDE_ARGS "/opt/moodle/code/" /var/www/html/

    echo "Generating stateless config.php from template..."
    
    cp "${MOODLE_DOCKER_ROOT}/templates/config.php.template" /var/www/html/config.php
    chown www-data:www-data /var/www/html/config.php
else
    # Workers wait for rsync and config.php to be finished by the app container
    echo "Worker mode: Waiting for Moodle source sync to complete..."
    TIMEOUT=60
    while [ ! -f /var/www/html/config.php ] && [ $TIMEOUT -gt 0 ]; do
        sleep 2
        TIMEOUT=$((TIMEOUT - 1))
    done
    if [ ! -f /var/www/html/config.php ]; then
        echo "ERROR: config.php not found after waiting. Is the 'app' container running?"
        exit 1
    fi
fi
