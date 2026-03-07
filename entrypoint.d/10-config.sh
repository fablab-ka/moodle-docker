#!/bin/bash
set -e

if [ "$IS_WORKER" = "false" ]; then
    echo "Generating stateless config.php from template..."
    
    cp "${MOODLE_DOCKER_ROOT}/templates/config.php.template" /var/www/html/config.php
    chown www-data:www-data /var/www/html/config.php
else
    # Workers wait for config.php to be created by the app container
    echo "Worker mode: Waiting for config.php to be created..."
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
