<?php
/**
 * Idempotent Moodle OAuth2 Issuer Management Script
 * 
 * Usage: php manage_oauth2_issuer.php /path/to/config.json
 */

define('CLI_SCRIPT', true);
require(__DIR__ . '/../config.php');
require_once($CFG->libdir . '/clilib.php');

// 1. Get arguments
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
    // Read from stdin
    $jsoncontent = file_get_contents('php://stdin');
}

if (empty($jsoncontent)) {
    cli_error("Error: No JSON configuration provided via file or stdin.");
}

$config = json_decode($jsoncontent, true);
if (json_last_error() !== JSON_ERROR_NONE) {
    cli_error("Error: Invalid JSON: " . json_last_error_msg());
}

}

// 2. Validate required fields
$required = ['name', 'baseurl', 'clientid', 'clientsecret'];
foreach ($required as $req) {
    if (empty($config[$req])) {
        cli_error("Error: Missing required field '$req' in JSON.");
    }
}

try {
    // 3. Find existing issuer by name or baseurl
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
        echo "Updating existing issuer: " . $existing->get('name') . " (ID: " . $existing->get('id') . ")
";
        $issuerdata->id = $existing->get('id');
        $issuer = \core\oauth2\api::update_issuer($issuerdata);
    } else {
        echo "Creating new issuer: " . $config['name'] . "
";
        $issuer = \core\oauth2\api::create_issuer($issuerdata);
    }

    $issuerid = $issuer->get('id');

    // 4. Synchronize Endpoints (Discovery)
    echo "Synchronizing endpoints via discovery...
";
    try {
        \core\oauth2\api::discover_endpoints($issuer);
    } catch (Exception $e) {
        echo "Warning: Discovery failed (this is normal if the provider doesn't support OIDC discovery): " . $e->getMessage() . "
";
    }

    // 5. Manage Field Mappings (Idempotent)
    if (!empty($config['field_mappings'])) {
        echo "Synchronizing field mappings...
";
        
        // Get existing mappings for this issuer
        $existing_mappings = \core\oauth2\api::get_user_field_mappings($issuer);
        
        foreach ($config['field_mappings'] as $external => $internal) {
            $found = false;
            foreach ($existing_mappings as $em) {
                if ($em->get('internalfield') === $internal) {
                    if ($em->get('externalfield') !== $external) {
                        echo "Updating mapping for $internal: $external
";
                        $em->set('externalfield', $external);
                        $em->save();
                    }
                    $found = true;
                    break;
                }
            }
            
            if (!$found) {
                echo "Creating new mapping: $external -> $internal
";
                \core\oauth2\api::create_user_field_mapping((object)[
                    'issuerid' => $issuerid,
                    'externalfield' => $external,
                    'internalfield' => $internal
                ]);
            }
        }
    }

    echo "Successfully managed OAuth2 Issuer: " . $issuer->get('name') . "
";

} catch (Exception $e) {
    cli_error("CRITICAL ERROR: " . $e->getMessage());
}
