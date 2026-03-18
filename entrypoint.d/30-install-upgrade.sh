#!/bin/bash
set -e

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
            sudo -u www-data -- php admin/cli/install_database.php \
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
            sudo -u www-data -- php /var/www/html/admin/cli/upgrade.php --non-interactive
        fi
    fi
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
