#!/bin/bash
set -e

# Define internal paths
export MOODLE_DOCKER_ROOT="/opt/moodle"

# Define if we are a worker/cron container
export IS_WORKER=false
if [[ "$1" == "cron" || "$1" == "worker" ]]; then
    export IS_WORKER=true
fi

INIT_TIME=$(date +%s%3N)

# Runner for modular entrypoint scripts
if [ -d "/docker-entrypoint.d" ]; then
    echo "Running entrypoint scripts in /docker-entrypoint.d/..."
    run-parts --verbose --exit-on-error --regex '.*\.sh$' /docker-entrypoint.d
fi

if [ "$IS_WORKER" = "false" ]; then
    INIT_TIME=$(($(date +%s%3N) - $INIT_TIME))
    echo "Init done (${INIT_TIME:0:(-3)}.${INIT_TIME:(-3)}s)"
fi

# Execution Phase
case "$1" in
    cron|worker)
        CRON_COUNT=${MOODLE_CRON_COUNT:-1}
        ADHOC_COUNT=${MOODLE_ADHOC_TASK_COUNT:-0}
        echo "Starting worker loop ($CRON_COUNT cron, $ADHOC_COUNT adhoc)..."
        while true; do
            for ((i=0; i<CRON_COUNT; i++)); do sudo -EHu www-data -- php /var/www/html/admin/cli/cron.php --keep-alive=59 & done
            for ((i=0; i<ADHOC_COUNT; i++)); do sudo -EHu www-data -- php /var/www/html/admin/cli/adhoc_task.php --execute --keep-alive=59 & done
            sleep 60
        done
        ;;
    php-fpm)
        exec "$@"
        ;;
    *)
        if [ -z "$1" ]; then exec php-fpm; else exec php-fpm "$@"; fi
        ;;
esac
