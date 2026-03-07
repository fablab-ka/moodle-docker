#!/bin/bash
set -e

if [ "$IS_WORKER" = "false" ]; then
    echo "Generating stateless config.php from template..."
    
    # Define variables to substitute to avoid touching PHP variables like $CFG
    VARS_TO_SUBST='$MOODLE_DB_TYPE:$MOODLE_DB_HOST:$MOODLE_DB_NAME:$MOODLE_DB_USER:$MOODLE_DB_PASS:$MOODLE_DB_PORT:$MOODLE_URL'
    
    envsubst "$VARS_TO_SUBST" < /var/www/html/templates/config.php.template > /var/www/html/config.php
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
