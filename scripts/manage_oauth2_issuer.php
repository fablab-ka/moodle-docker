#!/usr/bin/env php
<?php
/**
 * Idempotent Moodle OAuth2 Issuer Management Script
 *
 * Usage: php manage_oauth2_issuer.php /path/to/config.json
 */

define('CLI_SCRIPT', true);
require('/var/www/html/config.php');
require_once($CFG->libdir . '/clilib.php');

list($options, $unrecognized) = cli_get_params(
    ['help' => false],
    ['h' => 'help']
);

if ($options['help']) {
    echo "Usage: php manage_oauth2_issuer.php [json_config_file]\n";
    echo "If no file is provided, JSON is read from stdin.\n";
    exit(0);
}

if (!empty($unrecognized)) {
    $jsonfile = $unrecognized[0];
    if (!file_exists($jsonfile)) {
        cli_error("Error: File not found: $jsonfile");
    }
    $jsoncontent = file_get_contents($jsonfile);
} else {
    $jsoncontent = file_get_contents('php://stdin');
}

if (empty($jsoncontent)) {
    cli_error("Error: No JSON configuration provided via file or stdin.");
}

$config = json_decode($jsoncontent, true);
if (json_last_error() !== JSON_ERROR_NONE) {
    cli_error("Error: Invalid JSON: " . json_last_error_msg());
}

$required = ['name', 'baseurl', 'clientid', 'clientsecret'];
foreach ($required as $req) {
    if (empty($config[$req])) {
        cli_error("Error: Missing required field '$req' in JSON.");
    }
}

try {
    // Start session and log in as cron user (modified admin)
    \core\cron::setup_user();

    // Find existing issuer by name or baseurl
    $issuers = \core\oauth2\api::get_all_issuers();
    $existing = null;
    foreach ($issuers as $iss) {
        if ($iss->get('name') === $config['name'] || $iss->get('baseurl') === $config['baseurl']) {
            $existing = $iss;
            break;
        }
    }

    $issuerdata = (object)$config;
    // Remove field_mappings from the main issuer object before saving
    unset($issuerdata->field_mappings);

    if ($existing) {
        echo "Updating existing issuer: {$existing->get('name')} (ID: {$existing->get('id')})\n";
        $issuerdata->id = $existing->get('id');
        $issuer = \core\oauth2\api::update_issuer($issuerdata);
    } else {
        echo "Creating new issuer: {$config['name']}... ";
        $issuer = \core\oauth2\api::create_issuer($issuerdata);
        echo "ID: {$issuer->get('id')}\n";
    }

    $issuerid = $issuer->get('id');

    // Synchronize Endpoints (Discovery)
    echo "Synchronizing endpoints via discovery...\n";
    try {
        \core\oauth2\discovery\openidconnect::discover_endpoints($issuer);
    } catch (Exception $e) {
        echo "Warning: Discovery failed (this is normal if the provider doesn't support OIDC discovery): {$e->getMessage()}\n";
    }

    // Manage Field Mappings (Idempotent)
    if (!empty($config['field_mappings'])) {
        echo "Synchronizing field mappings...\n";

        // Get existing mappings for this issuer
        $existing_mappings = \core\oauth2\api::get_user_field_mappings($issuer);

        foreach ($config['field_mappings'] as $external => $internal) {
            $found = false;
            foreach ($existing_mappings as $em) {
                if ($em->get('internalfield') === $internal) {
                    if ($em->get('externalfield') !== $external) {
                        echo "Updating mapping: {$internal} -> {$external} (was {$em->get('externalfield')})\n";
                        $em->set('externalfield', $external);
                        $em->save();
                    }
                    $found = true;
                    break;
                }
            }

            if (!$found) {
                echo "Creating mapping: {$external} -> {$internal}\n";
                \core\oauth2\api::create_user_field_mapping((object)[
                    'issuerid' => $issuerid,
                    'externalfield' => $external,
                    'internalfield' => $internal
                ]);
            }
        }
    }

    echo "Successfully managed OAuth2 Issuer: {$issuer->get('name')}\n";

} catch (Exception $e) {
    cli_error("CRITICAL ERROR:\n{$e->getMessage()}\n");
} finally {
    \core\cron::reset_user_cache();
}
