/**
 * Upstream Update Checker for Moodle & PHP
 * 
 * This script checks for new Moodle tags and PHP image digest updates.
 * It is designed to be ran as a scheduled Komodo action.
 */

// --- Configuration ---
const GITHUB_OWNER = "your-username"; // Update this
const GITHUB_REPO = "moodle-docker"; // Update this
const GITHUB_TOKEN = "your-pat-token"; // Update this (needs 'repo' scope)

const PHP_TAGS = ["8.2-fpm-trixie", "8.3-fpm-trixie", "8.4-fpm-trixie"];
const MOODLE_UPSTREAM = "moodle/moodle";

// --- State Interface ---
interface State {
  lastMoodleVersion: string;
  lastPhpDigests: { [tag: string]: string };
  lastRepoTag?: string;
}

/**
 * Main logic - pass your persisted state here
 */
async function checkUpdates(state: State): Promise<State> {
  let updateDetected = false;
  const newState: State = JSON.parse(JSON.stringify(state));

  // --- 0. Check for Webhook Trigger (moodle-docker repo) ---
  // @ts-ignore - ARGS is provided by Komodo runtime
  if (typeof ARGS !== 'undefined' && ARGS.WEBHOOK_BODY) {
    try {
      const payload = JSON.parse(ARGS.WEBHOOK_BODY);
      // Check if this is a tag creation/push event (ref: refs/tags/v1.2.3)
      if (payload.ref && payload.ref.startsWith('refs/tags/')) {
        const newTag = payload.ref.replace('refs/tags/', '');
        if (newTag !== state.lastRepoTag) {
          console.log(`WEBHOOK: New tag detected in moodle-docker: ${newTag}`);
          newState.lastRepoTag = newTag;
          updateDetected = true;
        }
      }
    } catch (e) {
      console.error("Failed to parse WEBHOOK_BODY:", e);
    }
  }

  console.log("Fetching current configuration from main branch...");
  
  // 1. Fetch publish.yml to get dynamic config
  let phpTags: string[] = [];
  let moodleMajorMatch: string = "";
  try {
    const workflowUrl = `https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/.github/workflows/publish.yml`;
    const workflowRes = await fetch(workflowUrl);
    const workflowYaml = await workflowRes.text();

    // Extract MOODLE_MAJOR (e.g., 501)
    const majorMatch = workflowYaml.match(/MOODLE_MAJOR:\s*(\d+)/);
    moodleMajorMatch = majorMatch ? majorMatch[1] : "";

    // Extract PHP versions from matrix (e.g., ['8.2', '8.3', '8.4'])
    const phpMatch = workflowYaml.match(/php_version:\s*\[([^\]]+)\]/);
    if (phpMatch) {
      const versions = phpMatch[1].split(',').map(v => v.trim().replace(/['"]/g, ''));
      phpTags = versions.map(v => `${v}-fpm-trixie`);
    }

    if (!moodleMajorMatch || phpTags.length === 0) {
      throw new Error("Could not parse MOODLE_MAJOR or php_version from publish.yml");
    }
    
    console.log(`Config loaded: Moodle Major ${moodleMajorMatch}, PHP Tags: ${phpTags.join(", ")}`);
  } catch (e) {
    console.error("Failed to fetch/parse remote config:", e);
    return state; // Exit early if we can't get config
  }

  // 2. Check Moodle Tags (Filtered by major)
  try {
    const response = await fetch(`https://api.github.com/repos/${MOODLE_UPSTREAM}/tags`);
    const tags = await response.json();
    
    // Convert 501 -> 5.1 or 405 -> 4.5
    const majorStr = `${moodleMajorMatch[0]}.${parseInt(moodleMajorMatch.slice(1))}`;
    const tagRegex = new RegExp(`^v${majorStr.replace('.', '\\.')}\\.\\d+`);
    
    // Find the latest tag matching our major
    const latestTag = tags.find((t: any) => tagRegex.test(t.name))?.name;

    if (latestTag && latestTag !== state.lastMoodleVersion) {
      console.log(`NEW MOODLE VERSION DETECTED for ${majorStr}: ${latestTag} (was ${state.lastMoodleVersion})`);
      newState.lastMoodleVersion = latestTag;
      updateDetected = true;
    }
  } catch (e) {
    console.error("Failed to fetch Moodle tags:", e);
  }

  // 3. Check PHP Digests
  for (const tag of phpTags) {
    try {
      const response = await fetch(`https://hub.docker.com/v2/repositories/library/php/tags/${tag}`);
      const data = await response.json();
      // Use the digest of the first image (usually amd64 or the manifest list)
      const currentDigest = data.images?.[0]?.digest;

      if (currentDigest && currentDigest !== state.lastPhpDigests[tag]) {
        console.log(`NEW PHP DIGEST DETECTED for ${tag}: ${currentDigest} (was ${state.lastPhpDigests[tag]})`);
        newState.lastPhpDigests[tag] = currentDigest;
        updateDetected = true;
      }
    } catch (e) {
      console.error(`Failed to fetch digest for PHP tag ${tag}:`, e);
    }
  }

  // 3. Trigger GitHub Dispatch if updates found
  if (updateDetected) {
    console.log("Triggering GitHub workflow...");
    try {
      const dispatchResponse = await fetch(
        `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/dispatches`,
        {
          method: "POST",
          headers: {
            "Accept": "application/vnd.github.v3+json",
            "Authorization": `token ${GITHUB_TOKEN}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            event_type: "upstream_update",
            client_payload: {
              reason: "Upstream update detected by Komodo monitor script",
              moodle_version: newState.lastMoodleVersion
            },
          }),
        }
      );

      if (dispatchResponse.ok) {
        console.log("GitHub workflow triggered successfully.");
      } else {
        console.error("Failed to trigger GitHub workflow:", await dispatchResponse.text());
      }
    } catch (e) {
      console.error("Error triggering GitHub dispatch:", e);
    }
  } else {
    console.log("No updates found.");
  }

  return newState;
}

// --- Komodo Action Entry Point ---
// You will need to handle state persistence (e.g. via a file or database)
// Example usage:
/*
let myState: State = loadStateFromDisk(); 
myState = await checkUpdates(myState);
saveStateToDisk(myState);
*/
