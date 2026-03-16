#!/bin/bash
set -e

if [ "$IS_WORKER" = "false" ]; then
    if [ -n "$MOODLE_PLUGINS" ]; then
        echo "Post-Installation: Processing plugins..."
        pushd /var/www/html > /dev/null

        # Ensure config.php exists for moosh
        if [ ! -f config.php ]; then
            echo "Restoring config.php for moosh..."
            cp /opt/moodle/code/config.php .
            chown www-data:www-data config.php
        fi

        # Ensure install.php exists for moosh
        if [ ! -f install.php ]; then
            touch install.php
            chown www-data:www-data install.php
        fi

        # Download newest plugins.json for moosh
        echo "Updating moosh plugin list..."
        su -s /bin/bash -c "php -d memory_limit=512M -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_STRICT' -d display_errors=Off /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-list" www-data

        for plugin in $MOODLE_PLUGINS; do
            echo "Processing $plugin..."
            if [[ $plugin == http* ]]; then
                # Direct URL download
                echo "Downloading from URL..."
                curl -fSL "$plugin" -o "plugin_tmp.zip"
                unzip -o "plugin_tmp.zip"
                rm "plugin_tmp.zip"
                chown -R www-data:www-data .
            else
                # Using moosh for Moodle.org plugins
                # Run as www-data to avoid ownership/permission issues
                # Increase memory limit for moosh and suppress deprecations to avoid session issues
                echo "Installing via moosh (as www-data)..."
                su -s /bin/bash -c "php -d memory_limit=512M -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_STRICT' -d display_errors=Off /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-install $plugin" www-data
            fi
        done


        if [ "$MOODLE_AUTO_UPGRADE" = "true" ]; then
            echo "Running final upgrade check for plugins..."
            su -s /bin/bash -c "php admin/cli/upgrade.php --non-interactive" www-data
        else
            echo "NOTICE: MOODLE_AUTO_UPGRADE is not true. A manual upgrade via the Moodle UI or CLI is recommended to ensure plugins are properly installed and migrations have run."
        fi

        popd > /dev/null
    fi
fi
