<?php
/**
 * Moodle Plugin Cache Manager
 * 
 * Handles synchronization and transparent patching of Moosh's plugin database.
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
        $tmpFile = $argv[2] ?? null;
        $url = $argv[3] ?? null;
        if ($tmpFile && $url && file_exists($tmpFile)) {
            $hash = md5($url);
            $target = "$CACHE_DIR/$hash.zip";
            echo "Caching artifact: $url -> $target\n";
            if (!is_dir($CACHE_DIR)) {
                mkdir($CACHE_DIR, 0755, true);
            }
            rename($tmpFile, $target);
            chmod($target, 0644);
        } else {
            echo "Usage: store-artifact <tmp_file> <url>\n";
            exit(1);
        }
        break;

    case 'help':
    default:
        echo "Usage: php plugin_cache_manager.php <command> [args...]\n";
        echo "Commands:\n";
        echo "  sync-to-moosh             Copy plugins.json from volume to moosh dir\n";
        echo "  sync-from-moosh           Copy plugins.json from moosh dir to volume\n";
        echo "  apply-cache               Patch plugins.json with local paths for cached ZIPs\n";
        echo "  store-artifact <file> <url> Move a ZIP to cache named by URL hash\n";
        break;
}

function applyCache() {
    global $CACHE_DIR, $MOOSH_JSON;
    
    if (!file_exists($MOOSH_JSON)) {
        echo "No plugins.json found to patch.\n";
        return;
    }

    echo "Scanning cache for existing artifacts...\n";
    $json = json_decode(file_get_contents($MOOSH_JSON));
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
        echo "Successfully patched $patched URLs in plugins.json with local cache paths.\n";
    } else {
        echo "No new cached artifacts found to patch.\n";
    }
}
