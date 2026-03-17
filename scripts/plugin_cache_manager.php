<?php
/**
 * Moodle Plugin Cache Manager
 * 
 * Handles synchronization, downloading, and transparent patching of Moosh's plugin database.
 */

$CACHE_DIR = '/var/www/moodlecache';
$MOOSH_DIR = '/var/www/.moosh';
$MOOSH_JSON = "$MOOSH_DIR/plugins.json";
$CACHE_JSON = "$CACHE_DIR/plugins.json";

$command = $argv[1] ?? 'help';

switch ($command) {
    case 'sync-to-moosh':
        if (file_exists($CACHE_JSON)) {
            echo "Loading plugins.json from cache...\n";
            if (!is_dir($MOOSH_DIR)) {
                mkdir($MOOSH_DIR, 0755, true);
            }
            copy($CACHE_JSON, $MOOSH_JSON);
        }
        break;

    case 'sync-from-moosh':
        if (file_exists($MOOSH_JSON)) {
            echo "Saving plugins.json to cache...\n";
            if (!is_dir($CACHE_DIR)) {
                mkdir($CACHE_DIR, 0755, true);
            }
            copy($MOOSH_JSON, $CACHE_JSON);
        }
        break;

    case 'apply-cache':
        applyCache();
        break;

    case 'store-artifact':
        storeArtifact($argv[2] ?? null);
        break;

    case 'help':
    default:
        echo "Usage: php plugin_cache_manager.php <command> [args...]\n";
        echo "Commands:\n";
        echo "  sync-to-moosh             Copy plugins.json from volume to moosh dir\n";
        echo "  sync-from-moosh           Copy plugins.json from moosh dir to volume\n";
        echo "  apply-cache               Patch plugins.json with local paths for all cached ZIPs\n";
        echo "  store-artifact <input>    Download URL from input and patch plugins.json\n";
        break;
}

function storeArtifact($input) {
    global $CACHE_DIR;
    
    if (!$input) {
        echo "Usage: store-artifact <url_or_path>\n";
        exit(1);
    }

    // 1. Detect if it's already a local cache path
    if (strpos($input, $CACHE_DIR) !== false) {
        echo "Already cached (via path detection): $input\n";
        return;
    }

    // 2. Extract URL from input (handling potential extra text from moosh)
    if (preg_match('/(https?:\/\/[a-zA-Z0-9\.\/_-]+)/', $input, $matches)) {
        $url = $matches[1];
    } else {
        echo "No valid URL or cache path found in input.\n";
        return;
    }

    $hash = md5($url);
    $target = "$CACHE_DIR/$hash.zip";

    // 3. Download if missing
    if (!file_exists($target)) {
        echo "Cache miss. Downloading artifact: $url\n";
        if (!is_dir($CACHE_DIR)) {
            mkdir($CACHE_DIR, 0755, true);
        }
        
        if (!downloadFile($url, $target)) {
            echo "ERROR: Failed to download $url\n";
            exit(1);
        }
        chmod($target, 0644);
        echo "Successfully cached to $target\n";
    } else {
        echo "Cache hit: $target\n";
    }

    // 4. Always ensure the JSON is patched by calling the consolidated applyCache
    applyCache();
}

function downloadFile($url, $path) {
    $ch = curl_init($url);
    $fp = fopen($path, 'wb');
    curl_setopt($ch, CURLOPT_FILE, $fp);
    curl_setopt($ch, CURLOPT_HEADER, 0);
    curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
    curl_setopt($ch, CURLOPT_TIMEOUT, 300);
    $result = curl_exec($ch);
    curl_close($ch);
    fclose($fp);
    return $result;
}

function applyCache() {
    global $CACHE_DIR, $MOOSH_JSON;
    
    if (!file_exists($MOOSH_JSON)) {
        echo "No plugins.json found to patch.\n";
        return;
    }

    echo "Scanning cache for existing artifacts...\n";
    $content = file_get_contents($MOOSH_JSON);
    $json = json_decode($content);
    if (!$json || !isset($json->plugins)) {
        echo "Invalid plugins.json format.\n";
        return;
    }

    $patched = 0;
    foreach ($json->plugins as $plugin) {
        if (!isset($plugin->versions)) continue;
        foreach ($plugin->versions as $version) {
            // We only care about remote URLs
            if (strpos($version->downloadurl, 'http') !== 0) continue;

            $hash = md5($version->downloadurl);
            $local = "$CACHE_DIR/$hash.zip";
            
            if (file_exists($local)) {
                $version->downloadurl = $local;
                $patched++;
            }
        }
    }

    if ($patched > 0) {
        file_put_contents($MOOSH_JSON, json_encode($json));
        echo "Successfully patched $patched URL(s) in plugins.json with local cache paths.\n";
    } else {
        echo "No new cached artifacts found to patch.\n";
    }
}
