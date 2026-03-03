#!/bin/bash
set -e

# Define if we are a worker/cron container
IS_WORKER=false
if [[ "$1" == "cron" || "$1" == "worker" ]]; then
    IS_WORKER=true
fi

# --- 1. CONFIGURATION PHASE ---
if [ "$IS_WORKER" = "false" ]; then
    # Only the App container generates the config.php
    if [ ! -f /var/www/html/config.php ]; then
        echo "Generating stateless config.php..."
        cat <<EOF > /var/www/html/config.php
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = getenv('MOODLE_DB_TYPE') ?: 'pgsql';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = getenv('MOODLE_DB_HOST') ?: 'db';
\$CFG->dbname    = getenv('MOODLE_DB_NAME') ?: 'moodle';
\$CFG->dbuser    = getenv('MOODLE_DB_USER') ?: 'moodle';
\$CFG->dbpass    = getenv('MOODLE_DB_PASS') ?: 'moodle';
\$CFG->prefix    = 'mdl_';
\$CFG->dboptions = array (
  'dbpersist' => 0,
  'dbport' => getenv('MOODLE_DB_PORT') ?: '5432',
  'dbsocket' => '',
);

\$CFG->wwwroot   = getenv('MOODLE_URL') ?: 'http://localhost';
\$CFG->dataroot  = '/var/www/moodledata';
\$CFG->dirroot   = '/var/www/html';
\$CFG->libdir    = '/var/www/html';
\$CFG->admin     = 'admin';

\$CFG->directorypermissions = 0777;

// Proxy Settings
if (getenv('MOODLE_REVERSE_PROXY') === 'true') {
    \$CFG->reverseproxy = true;
}
if (getenv('MOODLE_SSL_PROXY') === 'true') {
    \$CFG->sslproxy = true;
}

// Forced Core Settings (MOODLE_CFG_ prefix)
foreach (\$_ENV as \$key => \$value) {
    if (strpos(\$key, 'MOODLE_CFG_') === 0) {
        \$cfg_name = strtolower(substr(\$key, 11));
        \$CFG->\$cfg_name = \$value;
    }
}

// Forced Plugin Settings (MOODLE_PLG_ prefix)
foreach (\$_ENV as \$key => \$value) {
    if (strpos(\$key, 'MOODLE_PLG_') === 0) {
        \$parts = explode('__', substr(\$key, 11));
        if (count(\$parts) === 2) {
            \$plugin = strtolower(\$parts[0]);
            \$setting = strtolower(\$parts[1]);
            \$CFG->forced_plugin_settings[\$plugin][\$setting] = \$value;
            \$CFG->forced_plugin_settings[\$plugin][\$setting . '_locked'] = true;
        }
    }
}

require_once(__DIR__ . '/lib/setup.php');
EOF
        chown www-data:www-data /var/www/html/config.php
    fi
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

# --- 2. DATABASE WAIT PHASE ---
echo "Waiting for database to be ready..."
MAX_RETRIES=30
[ "$IS_WORKER" = "true" ] && MAX_RETRIES=60 # Workers wait longer
RETRY_COUNT=0
until php -r "try { new PDO('pgsql:host=' . (getenv('MOODLE_DB_HOST') ?: 'db') . ';port=' . (getenv('MOODLE_DB_PORT') ?: '5432') . ';dbname=' . (getenv('MOODLE_DB_NAME') ?: 'moodle'), getenv('MOODLE_DB_USER') ?: 'moodle', getenv('MOODLE_DB_PASS') ?: 'moodle'); exit(0); } catch (Exception \$e) { exit(1); }"; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: Database connection timed out."
    exit 1
  fi
  echo "Database not ready yet... ($RETRY_COUNT/$MAX_RETRIES)"
  sleep 2
done
echo "Database is ready."

# --- 3. INITIALIZATION PHASE (APP ONLY) ---
if [ "$IS_WORKER" = "false" ]; then
    echo "Checking if Moodle is already installed..."
    IS_INSTALLED=$(php -r "
    try {
        \$pdo = new PDO('pgsql:host=' . (getenv('MOODLE_DB_HOST') ?: 'db') . ';port=' . (getenv('MOODLE_DB_PORT') ?: '5432') . ';dbname=' . (getenv('MOODLE_DB_NAME') ?: 'moodle'), getenv('MOODLE_DB_USER') ?: 'moodle', getenv('MOODLE_DB_PASS') ?: 'moodle');
        \$stmt = \$pdo->query(\"SELECT count(*) FROM information_schema.tables WHERE table_name = 'mdl_config'\");
        echo \$stmt->fetchColumn() > 0 ? 'true' : 'false';
    } catch (Exception \$e) {
        echo 'false';
    }
    ")

    if [ "$IS_INSTALLED" = "false" ]; then
        if [ "$MOODLE_DISABLE_INSTALL" != "true" ]; then
            echo "Moodle not installed. Starting automated installation..."
            if [ -z "$MOODLE_ADMIN_USER" ] || [ -z "$MOODLE_ADMIN_PASS" ] || [ -z "$MOODLE_ADMIN_EMAIL" ]; then
                echo "ERROR: Admin credentials missing."
                exit 1
            fi
            php admin/cli/install_database.php \
                --adminuser="$MOODLE_ADMIN_USER" \
                --adminpass="$MOODLE_ADMIN_PASS" \
                --adminemail="$MOODLE_ADMIN_EMAIL" \
                --agree-license \
                --fullname="$MOODLE_SITE_FULLNAME" \
                --shortname="$MOODLE_SITE_SHORTNAME"
        fi
    else
        echo "Moodle already installed."
        if [ "$MOODLE_AUTO_UPGRADE" = "true" ]; then
            echo "Starting automated upgrade..."
            php /var/www/html/admin/cli/upgrade.php --non-interactive
        fi
    fi

    # OAuth2 Configuration (App Only)
    for var in $(env | grep ^MOODLE_OAUTH2_CONFIG_ | cut -d= -f1); do
        CONFIG_VAL="${!var}"
        if [ -n "$CONFIG_VAL" ]; then
            echo "Configuring OAuth2 Issuer from $var..."
            php /var/www/html/scripts/manage_oauth2_issuer.php <<< "$CONFIG_VAL"
        fi
    done
else
    # Workers wait for installation to be finished by the App container
    echo "Worker mode: Waiting for Moodle installation to complete..."
    until php -r "
    try {
        \$pdo = new PDO('pgsql:host=' . (getenv('MOODLE_DB_HOST') ?: 'db') . ';port=' . (getenv('MOODLE_DB_PORT') ?: '5432') . ';dbname=' . (getenv('MOODLE_DB_NAME') ?: 'moodle'), getenv('MOODLE_DB_USER') ?: 'moodle', getenv('MOODLE_DB_PASS') ?: 'moodle');
        \$stmt = \$pdo->query(\"SELECT count(*) FROM information_schema.tables WHERE table_name = 'mdl_config'\");
        if (\$stmt->fetchColumn() > 0) exit(0); else exit(1);
    } catch (Exception \$e) { exit(1); }
    " > /dev/null 2>&1; do
        sleep 5
    done
    echo "Installation detected. Worker proceeding..."
fi

# --- 4. EXECUTION PHASE ---
case "$1" in
    cron|worker)
        CRON_COUNT=${MOODLE_CRON_COUNT:-1}
        ADHOC_COUNT=${MOODLE_ADHOC_TASK_COUNT:-0}
        echo "Starting worker loop ($CRON_COUNT cron, $ADHOC_COUNT adhoc)..."
        while true; do
            for ((i=0; i<CRON_COUNT; i++)); do
                php /var/www/html/admin/cli/cron.php --keep-alive=59 &
            done
            for ((i=0; i<ADHOC_COUNT; i++)); do
                php /var/www/html/admin/cli/adhoc_task.php --execute --keep-alive=59 &
            done
            sleep 60
        done
        ;;
    php-fpm)
        exec "$@"
        ;;
    *)
        if [ -z "$1" ]; then
            exec php-fpm
        else
            exec php-fpm "$@"
        fi
        ;;
esac
