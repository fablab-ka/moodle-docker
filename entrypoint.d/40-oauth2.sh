#!/bin/bash
set -e

VAR_PREFIX="MOODLE_OAUTH2_CONFIG_"

if [ "$IS_WORKER" = "false" ]; then
    # Automatic OAuth2 Issuer Configuration
    # Looks for MOODLE_OAUTH2_CONFIG_JSON or MOODLE_OAUTH2_CONFIG_<NAME>
    # Variables ending in _FILE are assumed to be paths to json configurations
    # Use 'env' to get all variables and filter
    for var in $(env | grep "^${VAR_PREFIX}" | cut -d= -f1); do
        CONFIG_VAL="${!var}"
        if [ -n "$CONFIG_VAL" ]; then
            issuer="${var:${#VAR_PREFIX}}"
            if [ "${issuer:(-5)}" = "_FILE" ] || [ "$issuer" = "FILE" ]; then
                [ "$issuer" = "FILE" ] && issuer="" || issuer="${issuer:0:(-5)}"

                echo "Configuring OAuth2 Issuer${issuer:- }$issuer from ${CONFIG_VAL}..."
                php "${MOODLE_DOCKER_ROOT}/scripts/manage_oauth2_issuer.php" "$CONFIG_VAL"
            else
                [ "$issuer" = "JSON" ] && issuer=""
                [ "${issuer:(-5)}" = "_JSON" ] && issuer="${issuer:0:(-5)}"

                echo "Configuring OAuth2 Issuer${issuer:- }$issuer from $var (via stdin)..."
                php "${MOODLE_DOCKER_ROOT}/scripts/manage_oauth2_issuer.php" <<< "$CONFIG_VAL"
            fi
        fi
    done

fi
