#!/bin/bash
set -e

CACHE_DIR="/var/www/moodlecache"
MOOSH_DIR="/var/www/.moosh"
# Run commands with increased memory limit and suppress deprecations
CACHE_MANAGER="php -d memory_limit=512M /opt/moodle/scripts/plugin_cache_manager.php"
MOOSH_BIN="php -d memory_limit=512M -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_STRICT' -d display_errors=Off /usr/local/bin/moosh --moodle-path=/var/www/html/public"

if [ "$IS_WORKER" = "false" ]; then
    if [ -n "$MOODLE_PLUGINS" ]; then
        echo "Post-Installation: Processing plugins..."
        pushd /var/www/html/public > /dev/null

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

        # Ensure moosh directory exists and is writable
        mkdir -p "$MOOSH_DIR"
        chown www-data:www-data "$MOOSH_DIR"

        # --- Phase 1: Sync and Refresh Database ---
        # Load existing database from cache volume if available
        $CACHE_MANAGER sync-to-moosh

        # Refresh the plugin list (moosh handles age check)
        echo "Updating moosh plugin list..."
        su -s /bin/bash -c "$MOOSH_BIN -n plugin-list" www-data > /dev/null
        
        # Patch local database with any known cached items
        $CACHE_MANAGER apply-cache
        
        # Persist the patched database back to cache volume
        $CACHE_MANAGER sync-from-moosh

        # --- Phase 2: Caching Loop ---
        for plugin in $MOODLE_PLUGINS; do
            if [[ $plugin == http* ]]; then
                echo "Plugin $plugin is a URL, skipping cache patching (direct download)."
                continue
            fi

            echo "Checking cache for $plugin..."
            
            # Get the raw resolution result from Moosh (redirect stderr to catch everything)
            # Moosh returns either a URL or a local path (if already patched)
            RESULT=$(su -s /bin/bash -c "$MOOSH_BIN -n plugin-download -u $plugin" www-data 2>&1 || true)

            # Delegate download and patching to the cache manager
            # The manager is smart enough to ignore local paths and handle partial moosh output
            $CACHE_MANAGER store-artifact "$RESULT"
        done

        # --- Phase 3: Installation ---
        for plugin in $MOODLE_PLUGINS; do
            if [[ $plugin == http* ]]; then
                echo "Installing $plugin (Direct URL)..."
                curl -fSL "$plugin" -o "plugin_tmp.zip"
                unzip -o "plugin_tmp.zip"
                rm "plugin_tmp.zip"
                chown -R www-data:www-data .
            else
                echo "Installing $plugin via moosh..."
                # Moosh will now find the local path in plugins.json for all cached items
                su -s /bin/bash -c "$MOOSH_BIN -n plugin-install $plugin" www-data
            fi
        done
        
        if [ "$MOODLE_AUTO_UPGRADE" = "true" ]; then
            echo "Running final upgrade check for plugins..."
            su -s /bin/bash -c "cd /var/www/html && php admin/cli/upgrade.php --non-interactive" www-data
        else
            echo "NOTICE: MOODLE_AUTO_UPGRADE is not true. A manual upgrade via the Moodle UI or CLI is recommended to ensure plugins are properly installed and migrations have run."
        fi
        
        popd > /dev/null
    fi
fi
