#!/bin/bash
set -e

CACHE_DIR="/var/www/moodlecache"
MOOSH_DIR="/var/www/.moosh"

if [ "$IS_WORKER" = "false" ]; then
    if [ -n "$MOODLE_PLUGINS" ]; then
        echo "Post-Installation: Processing plugins..."
        pushd /var/www/html/public > /dev/null
        
        # Ensure config.php exists for moosh (required even for plugin-download -u)
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

        # --- Phase 1: Sync plugins.json ---
        mkdir -p "$MOOSH_DIR"
        chown www-data:www-data "$MOOSH_DIR"

        if [ -f "$CACHE_DIR/plugins.json" ]; then
            echo "Loading plugins.json from cache..."
            cp "$CACHE_DIR/plugins.json" "$MOOSH_DIR/plugins.json"
            chown www-data:www-data "$MOOSH_DIR/plugins.json"
        fi

        # Check if plugins.json is too old or missing (moosh will handle the download)
        # We run plugin-list to ensure we have a fresh database
        echo "Updating moosh plugin list..."
        su -s /bin/bash -c "php -d memory_limit=512M /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-list" www-data
        
        # Save fresh plugins.json back to cache
        cp "$MOOSH_DIR/plugins.json" "$CACHE_DIR/plugins.json"

        # --- Phase 2: Caching Loop ---
        for plugin in $MOODLE_PLUGINS; do
            if [[ $plugin == http* ]]; then
                echo "Plugin $plugin is a URL, skipping cache patching (direct download)."
                continue
            fi

            echo "Checking cache for $plugin..."
            
            # Resolve the correct download URL for this environment
            # Note: moosh plugin-download -u returns just the URL string
            URL=$(su -s /bin/bash -c "php -d memory_limit=512M /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-download -u $plugin" www-data | grep "^http" | head -n 1)
            
            if [ -z "$URL" ]; then
                echo "Could not resolve URL for $plugin, Moosh might handle it during install."
                continue
            fi

            # Create a deterministic filename based on the URL
            URL_HASH=$(echo -n "$URL" | md5sum | cut -d' ' -f1)
            CACHE_FILE="$CACHE_DIR/$URL_HASH.zip"

            if [ ! -f "$CACHE_FILE" ]; then
                echo "Cache miss for $plugin. Downloading..."
                # Download to a temporary location first
                su -s /bin/bash -c "php -d memory_limit=512M /usr/local/bin/moosh --moodle-path=/var/www/html/public -n plugin-download $plugin" www-data
                
                # Moosh downloads to current dir, usually named [plugin].zip
                # But it's safer to find the most recent zip
                DOWNLOADED_ZIP=$(ls -t *.zip | head -n 1)
                if [ -n "$DOWNLOADED_ZIP" ]; then
                    mv "$DOWNLOADED_ZIP" "$CACHE_FILE"
                    chown www-data:www-data "$CACHE_FILE"
                    echo "Cached $plugin to $CACHE_FILE"
                fi
            else
                echo "Cache hit for $plugin."
            fi

            # Patch plugins.json to point to the local file
            # We use PHP to safely manipulate the JSON
            if [ -f "$CACHE_FILE" ]; then
                echo "Patching plugins.json for $plugin -> $CACHE_FILE"
                php -r "
                    \$json = json_decode(file_get_contents('$MOOSH_DIR/plugins.json'));
                    \$targetUrl = '$URL';
                    \$localPath = '$CACHE_FILE';
                    \$found = false;
                    foreach (\$json->plugins as \$p) {
                        if (isset(\$p->versions)) {
                            foreach (\$p->versions as \$v) {
                                if (\$v->downloadurl === \$targetUrl) {
                                    \$v->downloadurl = \$localPath;
                                    \$found = true;
                                    break 2;
                                }
                            }
                        }
                    }
                    if (\$found) {
                        file_put_contents('$MOOSH_DIR/plugins.json', json_encode(\$json));
                    }
                "
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
                # Moosh will now find the local path in plugins.json
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
