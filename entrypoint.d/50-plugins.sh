#!/bin/bash
set -e

CACHE_DIR="/var/www/moodlecache"
MOOSH_DIR="/var/www/.moosh"
CACHE_MANAGER="php -d memory_limit=512M /opt/moodle/scripts/plugin_cache_manager.php"
# Run moosh with increased memory limit,
# suppress deprecations to avoid session issues,
# and explicitly specify the moodle path.
MOOSH_BIN="php -d memory_limit=512M -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_STRICT' -d display_errors=Off /usr/local/bin/moosh --moodle-path=/var/www/html/public"

if [ "$IS_WORKER" = "false" ]; then
    if [ -n "$MOODLE_PLUGINS" ]; then
        echo "Post-Installation: Processing plugins..."
        # Change to the public directory for Moosh commands
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

        # --- Phase 1: Sync and Refresh Database ---
        # Load existing database from cache volume if available
        $CACHE_MANAGER sync-to-moosh

        # Refresh the plugin list (moosh handles age check)
        echo "Updating moosh plugin list..."
        su -s /bin/bash -c "php -d memory_limit=512M -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_STRICT' -d display_errors=Off /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-list" www-data > /dev/null
        
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
            # Note: moosh output might contain other text, we need just the URL
            # If we already patched plugins.json, moosh might return the local path here!
            RAW_OUT=$(su -s /bin/bash -c "php -d memory_limit=512M -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_STRICT' -d display_errors=Off /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-download -u $plugin" www-data 2>&1 || true)
            
            # Check if it's already a local path in our cache
            if echo "$RAW_OUT" | grep -q "$CACHE_DIR"; then
                URL_OR_PATH=$(echo "$RAW_OUT" | grep -o "$CACHE_DIR/[a-f0-9]\+\.zip" | head -n 1)
                echo "Cache hit (via plugins.json) for $plugin: $URL_OR_PATH"
                continue
            fi

            URL=$(echo "$RAW_OUT" | grep -oE "https?://[a-zA-Z0-9\./_-]+" | head -n 1)

            if [ -z "$URL" ]; then
                echo "Could not resolve URL for $plugin. Moosh output was:"
                echo "$RAW_OUT"
                continue
            fi

            echo "Resolved URL for $plugin: $URL"
            URL_HASH=$(echo -n "$URL" | md5sum | cut -d' ' -f1)
            CACHE_FILE="$CACHE_DIR/$URL_HASH.zip"
            echo "Expected cache file: $CACHE_FILE"

            if [ ! -f "$CACHE_FILE" ]; then
                echo "Cache miss for $plugin. Downloading..."
                su -s /bin/bash -c "php -d memory_limit=512M -d error_reporting='E_ALL & ~E_DEPRECATED & ~E_STRICT' -d display_errors=Off /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-download $plugin" www-data
                
                # Find the downloaded zip (it's in the current dir /var/www/html/public)
                DOWNLOADED_ZIP=$(ls -t *.zip 2>/dev/null | head -n 1)
                if [ -n "$DOWNLOADED_ZIP" ]; then
                    echo "Found downloaded zip: $DOWNLOADED_ZIP. Storing in cache..."
                    # Move to cache volume using the manager (handles naming/hashing)
                    $CACHE_MANAGER store-artifact "$DOWNLOADED_ZIP" "$URL"
                    
                    # Re-patch the JSON to reflect the new local file
                    $CACHE_MANAGER apply-cache
                else
                    echo "ERROR: Could not find downloaded ZIP for $plugin"
                fi
            else
                echo "Cache hit for $plugin."
            fi
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
            # Moodle CLI scripts are in /var/www/html/admin/cli
            su -s /bin/bash -c "cd /var/www/html && php admin/cli/upgrade.php --non-interactive" www-data
        else
            echo "NOTICE: MOODLE_AUTO_UPGRADE is not true. A manual upgrade via the Moodle UI or CLI is recommended to ensure plugins are properly installed and migrations have run."
        fi
        
        popd > /dev/null
    fi
fi
