#!/bin/bash
set -e

CACHE_DIR="/var/www/plugincache"
MOOSH_DIR="/var/www/.moosh"
# Run commands with increased memory limit and suppress deprecations
CACHE_MANAGER=(php -d memory_limit=512M /opt/moodle/scripts/plugin_cache_manager.php)
MOOSH_BIN=(php -d memory_limit=512M -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_STRICT' -d display_errors=Off /usr/local/bin/moosh --moodle-path=/var/www/html/public)

if [ "$IS_WORKER" = "false" ]; then
    if [ -n "$MOODLE_PLUGINS" ]; then
        echo "Post-Installation: Processing plugins..."
        pushd /var/www/html/public > /dev/null

        # Ensure config.php exists for moosh (it should be in /var/www/html/public)
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

        # Ensure moosh directory exists and is writable
        mkdir -p "$MOOSH_DIR"
        chown www-data:www-data "$MOOSH_DIR"

        # Load existing database from cache volume if available
        sudo -EHu www-data -- "${CACHE_MANAGER[@]}" sync-to-moosh

        # Refresh the plugin list (moosh handles age check)
        echo "Updating moosh plugin list..."
        sudo -EHu www-data -- "${MOOSH_BIN[@]}" -n plugin-list > /dev/null

        # Patch local database with any known cached items
        sudo -EHu www-data -- "${CACHE_MANAGER[@]}" apply-cache

        # Persist the patched database back to cache volume
        sudo -EHu www-data -- "${CACHE_MANAGER[@]}" sync-from-moosh

        for plugin in $MOODLE_PLUGINS; do
            # Download and extract URLs directly
            if [[ $plugin == http* ]]; then
                echo "Installing plugin: $plugin"
                curl -fSL "$plugin" -o "plugin_tmp.zip"
                sudo -EHu www-data -- unzip -o "plugin_tmp.zip"
                rm "plugin_tmp.zip"
                continue
            fi

            echo -n "Resolving $plugin: "

            # Resolve the correct download URL for this environment
            # Note: moosh output might contain other text, we need to extract
            # either a URL (http...) or a local cache path (/var/www/plugincache/...)
            moosh_out=$(sudo -EHu www-data -- "${MOOSH_BIN[@]}" -n plugin-download -u $plugin 2>&1 || true)
            plugin_uri=$(grep -oE "(https?://|$CACHE_DIR/)[^[:space:]]+" <<< "$moosh_out" | head -n 1)

            echo "${plugin_uri:-(unknown)}"

            if [ -z "$plugin_uri" ]; then
                echo "Could not resolve plugin URI from moosh:"
                echo "$moosh_out"
            else
                sudo -EHu www-data -- "${CACHE_MANAGER[@]}" store-artifact "$plugin_uri"
            fi

            echo "Installing $plugin..."
            # Moosh will now find the local path in plugins.json for all cached items
            sudo -EHu www-data -- "${MOOSH_BIN[@]}" -n plugin-install "$plugin"
        done

        if [ -n "$MOODLE_PLUGINS" ]; then
            if [ "$MOODLE_AUTO_UPGRADE" = "true" ]; then
                echo "Running final upgrade check for plugins..."
                pushd /var/www/html > /dev/null
                sudo -EHu www-data -- php admin/cli/upgrade.php --non-interactive
                popd > /dev/null
            else
                echo "NOTICE: MOODLE_AUTO_UPGRADE is not true. A manual upgrade via the Moodle UI or CLI is recommended to ensure plugins are properly installed and migrations have run."
            fi
        fi

        popd > /dev/null
    fi
fi
