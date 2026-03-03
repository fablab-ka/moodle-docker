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
  moodleVersion: string;
  phpDigests: Record<string, string>;
  repoTag: string;
}

interface WorkflowConfig {
  moodleMajor: string;
  phpTags: string[];
}

type Checker = (state: State, config: WorkflowConfig) => Promise<boolean>;

/**
 * 0. Check for Webhook Trigger (moodle-docker repo)
 */
function checkWebhookTrigger(state: State): boolean {
  // @ts-ignore - ARGS is provided by Komodo runtime
  if (typeof ARGS !== 'undefined' && ARGS.WEBHOOK_BODY) {
    const payload = ARGS.WEBHOOK_BODY;
    if (payload.ref && payload.ref.startsWith('refs/tags/')) {
      const newTag = payload.ref.replace('refs/tags/', '');
      if (newTag !== state.repoTag) {
        console.log(`WEBHOOK: New tag detected in moodle-docker: ${newTag}`);
        state.repoTag = newTag;
        return true;
      }
    }
  }
  return false;
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
const createGitChecker = (repo: string, stateKey: keyof State, filter: (tag: any, config: WorkflowConfig, state: State) => boolean): Checker => 
  async (state, config) => {
    try {
      const response = await fetch(`https://api.github.com/repos/${repo}/tags`);
      const tags = await response.json();
      const latest = tags.find((t: any) => filter(t, config, state))?.name;

      if (latest && latest !== state[stateKey]) {
        console.log(`NEW ${repo} VERSION: ${latest} (was ${state[stateKey]})`);
        state[stateKey] = latest as any;
        return true;
      }
    } catch (e) {
      console.error(`Git tag check failed for ${repo}:`, e);
    }
    return false;
  };

/**
 * Generic Docker Digest Checker Factory
 */
const createDockerChecker = (registry: string, stateKey: 'phpDigests'): Checker => 
  async (state, config) => {
    let detected = false;
    // Assume config has a list of tags to check for this registry
    // In our case, we always check config.phpTags
    for (const tag of config.phpTags) {
      try {
        const response = await fetch(`https://hub.docker.com/v2/repositories/${registry}/tags/${tag}`);
        const data = await response.json();
        const current = data.images?.[0]?.digest;

        if (current && current !== state[stateKey][tag]) {
          console.log(`NEW ${registry}:${tag} DIGEST: ${current}`);
          state[stateKey][tag] = current;
          detected = true;
        }
      } catch (e) {
        console.error(`Docker digest check failed for ${registry}:${tag}:`, e);
      }
    }
    return detected;
  };

// Specialized Checkers
const checkMoodle = createGitChecker(MOODLE_UPSTREAM, 'moodleVersion', (tag, config) => {
  const major = config.moodleMajor;
  const majorStr = `${major[0]}.${parseInt(major.slice(1))}`;
  return new RegExp(`^v${majorStr.replace('.', '\\.')}\\.\\d+`).test(tag.name);
});

const checkPhp = createDockerChecker("library/php", 'phpDigests');

/**
 * 4. Trigger GitHub Repository Dispatch
 */
async function triggerDispatch(state: State): Promise<boolean> {
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
        client_payload: {
          moodle_version: state.moodleVersion,
          repo_tag: state.repoTag
        },
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
  const newState: State = JSON.parse(JSON.stringify(state));
  
  // 0. Synchronous Webhook Check
  const webhookDetected = checkWebhookTrigger(newState);

  return fetchWorkflowConfig()
    .then(config => {
      if (!config) throw new Error("ConfigFetchFailed");
      
      // 1. Run Checkers in Parallel
      const checkers: Checker[] = [checkMoodle, checkPhp];
      return Promise.all([
        Promise.resolve(config),
        ...checkers.map(check => check(newState, config))
      ]);
    })
    .then(([config, ...results]) => {
      const updatesDetected = results.some(r => r === true) || webhookDetected;

      if (updatesDetected) {
        return triggerDispatch(newState).then(success => {
          if (success) console.log("Build triggered successfully.");
          return newState;
        });
      }

      console.log("No updates found.");
      return newState;
    })
    .catch(err => {
      if (err.message === "ConfigFetchFailed") return state;
      console.error("Pipeline error:", err);
      return state;
    });
}
