#!/bin/bash
set -e

if [ "$IS_WORKER" = "false" ]; then
    # Automatic OAuth2 Issuer Configuration
    # Looks for MOODLE_OAUTH2_CONFIG_JSON or MOODLE_OAUTH2_CONFIG_<NAME>
    # Use 'env' to get all variables and filter
    for var in $(env | grep ^MOODLE_OAUTH2_CONFIG_ | cut -d= -f1); do
        CONFIG_VAL="${!var}"
        if [ -n "$CONFIG_VAL" ]; then
            echo "Configuring OAuth2 Issuer from $var (via stdin)..."
            php /var/www/html/scripts/manage_oauth2_issuer.php <<< "$CONFIG_VAL"
        fi
    done
fi
