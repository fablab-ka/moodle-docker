#!/bin/bash
set -e

CACHE_DIR="/var/www/moodlecache"
MOOSH_DIR="/var/www/.moosh"
CACHE_MANAGER="php /opt/moodle/scripts/plugin_cache_manager.php"

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

        # --- Phase 1: Sync and Refresh Database ---
        # Load existing database from cache volume if available
        $CACHE_MANAGER sync-to-moosh

        # Refresh the plugin list (moosh handles age check)
        echo "Updating moosh plugin list..."
        su -s /bin/bash -c "php -d memory_limit=512M /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-list" www-data
        
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
            
            # Resolve the correct download URL for this environment
            URL=$(su -s /bin/bash -c "php -d memory_limit=512M /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-download -u $plugin" www-data | grep "^http" | head -n 1)
            
            if [ -z "$URL" ]; then
                echo "Could not resolve URL for $plugin, Moosh might handle it during install."
                continue
            fi

            URL_HASH=$(echo -n "$URL" | md5sum | cut -d' ' -f1)
            CACHE_FILE="$CACHE_DIR/$URL_HASH.zip"

            if [ ! -f "$CACHE_FILE" ]; then
                echo "Cache miss for $plugin. Downloading..."
                su -s /bin/bash -c "php -d memory_limit=512M /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-download $plugin" www-data
                
                # Find the downloaded zip
                DOWNLOADED_ZIP=$(ls -t *.zip | head -n 1)
                if [ -n "$DOWNLOADED_ZIP" ]; then
                    # Move to cache volume using the manager (handles naming/hashing)
                    $CACHE_MANAGER store-artifact "$DOWNLOADED_ZIP" "$URL"
                    
                    # Re-patch the JSON to reflect the new local file
                    $CACHE_MANAGER apply-cache
                fi
            else
                echo "Cache hit for $plugin."
            fi
        done

        # --- Phase 3: Installation ---
        for plugin in $MOODLE_PLUGINS; do
            echo "Installing $plugin..."
            if [[ $plugin == http* ]]; then
                echo "Downloading from URL..."
                curl -fSL "$plugin" -o "plugin_tmp.zip"
                unzip -o "plugin_tmp.zip"
                rm "plugin_tmp.zip"
                chown -R www-data:www-data .
            else
                # Moosh will now find the local path in plugins.json for all cached items
                su -s /bin/bash -c "php -d memory_limit=512M /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-install $plugin" www-data
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
