/**
 * Upstream Update Checker for Moodle & PHP
 * 
 * This script checks for new Moodle tags and PHP image digest updates.
 * It is designed to be ran as a scheduled Komodo action or triggered via Webhook.
 */

// --- Configuration ---
const GITHUB_OWNER = "your-username"; 
const GITHUB_REPO = "moodle-docker";
const GITHUB_TOKEN = "your-pat-token"; 

const MOODLE_UPSTREAM = "moodle/moodle";

// --- State & Config Interfaces ---
interface State {
  lastMoodleVersion: string;
  lastPhpDigests: { [tag: string]: string };
  lastRepoTag?: string;
}

interface WorkflowConfig {
  moodleMajor: string;
  phpTags: string[];
}

/**
 * 0. Check for Webhook Trigger (moodle-docker repo)
 */
function checkWebhookTrigger(state: State): { detected: boolean; newTag?: string } {
  // @ts-ignore - ARGS is provided by Komodo runtime
  if (typeof ARGS !== 'undefined' && ARGS.WEBHOOK_BODY) {
    const payload = ARGS.WEBHOOK_BODY;
    if (payload.ref && payload.ref.startsWith('refs/tags/')) {
      const newTag = payload.ref.replace('refs/tags/', '');
      if (newTag !== state.lastRepoTag) {
        console.log(`WEBHOOK: New tag detected in moodle-docker: ${newTag}`);
        return { detected: true, newTag };
      }
    }
  }
  return { detected: false };
}

/**
 * 1. Fetch current publish.yml to get dynamic configuration
 */
async function fetchWorkflowConfig(): Promise<WorkflowConfig | null> {
  console.log("Fetching current configuration from main branch...");
  try {
    const url = `https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/.github/workflows/publish.yml`;
    const res = await fetch(url);
    const yaml = await res.text();

    const majorMatch = yaml.match(/MOODLE_MAJOR:\s*(\d+)/);
    const phpMatch = yaml.match(/php_version:\s*\[([^\]]+)\]/);

    if (!majorMatch || !phpMatch) throw new Error("Parse error");

    const phpTags = phpMatch[1]
      .split(',')
      .map(v => `${v.trim().replace(/['"]/g, '')}-fpm-trixie`);

    return { moodleMajor: majorMatch[1], phpTags };
  } catch (e) {
    console.error("Failed to fetch workflow config:", e);
    return null;
  }
}

/**
 * Generic Git Tag Checker Factory
 */
const createGitTagChecker = (repo: string) => async (major: string, lastVersion: string) => {
  try {
    const response = await fetch(`https://api.github.com/repos/${repo}/tags`);
    const tags = await response.json();
    
    const majorStr = `${major[0]}.${parseInt(major.slice(1))}`;
    const tagRegex = new RegExp(`^v${majorStr.replace('.', '\\.')}\\.\\d+`);
    const latest = tags.find((t: any) => tagRegex.test(t.name))?.name;

    if (latest && latest !== lastVersion) {
      console.log(`NEW ${repo} VERSION: ${latest} (was ${lastVersion})`);
      return { detected: true, latest };
    }
  } catch (e) {
    console.error(`Git tag check failed for ${repo}:`, e);
  }
  return { detected: false };
};

/**
 * Generic Docker Digest Checker Factory
 */
const createDockerDigestChecker = (repository: string) => async (tags: string[], lastDigests: { [tag: string]: string }) => {
  let detected = false;
  const digests = { ...lastDigests };

  for (const tag of tags) {
    try {
      const response = await fetch(`https://hub.docker.com/v2/repositories/${repository}/tags/${tag}`);
      const data = await response.json();
      const current = data.images?.[0]?.digest;

      if (current && current !== lastDigests[tag]) {
        console.log(`NEW ${repository}:${tag} DIGEST: ${current}`);
        digests[tag] = current;
        detected = true;
      }
    } catch (e) {
      console.error(`Docker digest check failed for ${repository}:${tag}:`, e);
    }
  }
  return { detected, digests };
};

// Specialized Checkers
const checkMoodleUpdate = createGitTagChecker(MOODLE_UPSTREAM);
const checkPhpUpdates = createDockerDigestChecker("library/php");

/**
 * 4. Trigger GitHub Repository Dispatch
 */
async function triggerDispatch(moodleVersion: string): Promise<boolean> {
  console.log("Triggering GitHub workflow...");
  try {
    const res = await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/dispatches`, {
      method: "POST",
      headers: {
        "Accept": "application/vnd.github.v3+json",
        "Authorization": `token ${GITHUB_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        event_type: "upstream_update",
        client_payload: { moodle_version: moodleVersion },
      }),
    });
    return res.ok;
  } catch (e) {
    console.error("Dispatch trigger failed:", e);
    return false;
  }
}

/**
 * Main Orchestrator (Promise Chain)
 */
async function checkUpdates(state: State): Promise<State> {
  const context = {
    newState: JSON.parse(JSON.stringify(state)),
    triggerReason: ""
  };

  // 0. Initial Webhook Check (Synchronous)
  const webhook = checkWebhookTrigger(state);
  if (webhook.detected) {
    context.newState.lastRepoTag = webhook.newTag;
    context.triggerReason = "webhook";
  }

  // 1. Fetch Config -> 2. Parallel Upstream Checks -> 3. Decision & Dispatch
  return fetchWorkflowConfig()
    .then(config => {
      if (!config) throw new Error("ConfigFetchFailed");
      
      return Promise.all([
        Promise.resolve(config),
        checkMoodleUpdate(config.moodleMajor, state.lastMoodleVersion),
        checkPhpUpdates(config.phpTags, state.lastPhpDigests)
      ]);
    })
    .then(([config, moodle, php]) => {
      if (moodle.detected) {
        context.newState.lastMoodleVersion = moodle.latest;
        context.triggerReason = context.triggerReason || "moodle";
      }
      if (php.detected) {
        context.newState.lastPhpDigests = php.digests;
        context.triggerReason = context.triggerReason || "php";
      }

      if (context.triggerReason) {
        return triggerDispatch(context.newState.lastMoodleVersion).then(success => {
          if (success) console.log(`Build triggered successfully (Reason: ${context.triggerReason})`);
          return context.newState;
        });
      }

      console.log("No updates found.");
      return context.newState;
    })
    .catch(err => {
      if (err.message === "ConfigFetchFailed") return state;
      console.error("Pipeline error:", err);
      return state;
    });
}
