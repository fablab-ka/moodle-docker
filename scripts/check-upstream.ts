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
  github: Record<string, string>;
  dockerhub: Record<string, string>;
  repoTag?: string;
  triggers: string[];
}

interface WorkflowConfig {
  moodleMajor: string;
  phpVersions: string[]; // e.g. ["8.2", "8.3", "8.4"]
}

type Checker = (state: State, config: WorkflowConfig) => Promise<void>;

/**
 * 0. Check for Webhook Trigger
 */
function checkWebhookTrigger(state: State): void {
  // @ts-ignore - ARGS is provided by Komodo runtime
  if (typeof ARGS !== 'undefined' && ARGS.WEBHOOK_BODY) {
    const payload = ARGS.WEBHOOK_BODY;
    if (payload.ref && payload.ref.startsWith('refs/tags/')) {
      const newTag = payload.ref.replace('refs/tags/', '');
      if (newTag !== '' && newTag !== state.repoTag) {
        console.log(`WEBHOOK: New tag detected in webhook payload: ${newTag}`);
        state.repoTag = newTag;
        state.triggers.push(`repo:${newTag}`);
      }
    }
  }
}

/**
 * 1. Fetch current publish.yml to get dynamic configuration
 */
async function fetchWorkflowConfig(): Promise<WorkflowConfig | null> {
  console.log("Fetching current configuration from main branch...");
  try {
    const url = `https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/.github/workflows/publish.yml`;
    const yaml = await fetch(url).then(r => r.text());

    const majorMatch = yaml.match(/MOODLE_MAJOR:\s*(\d+)/);
    const phpMatch = yaml.match(/php_version:\s*\[([^\]]+)\]/);

    if (!majorMatch || !phpMatch) throw new Error("Parse error");

    const phpVersions = phpMatch[1]
      .split(',')
      .map(v => v.trim().replace(/['"]/g, ''));

    return { moodleMajor: majorMatch[1], phpVersions };
  } catch (e) {
    console.error("Failed to fetch workflow config:", e);
    return null;
  }
}

/**
 * Syncs the state with the current workflow configuration
 */
function syncState(state: State, config: WorkflowConfig) {
  // Sync GitHub (Moodle)
  const currentMajors = [config.moodleMajor];
  Object.keys(state.github).forEach(k => {
    if (!currentMajors.includes(k)) delete state.github[k];
  });
  currentMajors.forEach(k => {
    if (!(k in state.github)) state.github[k] = "";
  });

  // Sync DockerHub (PHP)
  const currentPhpTags = config.phpVersions.map(v => `${v}-fpm`);
  Object.keys(state.dockerhub).forEach(k => {
    if (!currentPhpTags.includes(k)) delete state.dockerhub[k];
  });
  currentPhpTags.forEach(k => {
    if (!(k in state.dockerhub)) state.dockerhub[k] = "";
  });
}

/**
 * Generic Git Tag Checker Factory
 */
const createGitChecker = (repo: string, filter: string | (tag: any, context: string) => boolean): Checker =>
  async (state, config) => {
    try {
      const response = await fetch(`https://api.github.com/repos/${repo}/tags`);
      const tags = await response.json();
      if (typeof filter === 'string') filter = ((f: string, tag: any, context: string) => new RegExp(f).test(tag.name)).bind(null, filter);
      
      // We check for all keys currently in the github state for this checker
      for (const major of Object.keys(state.github)) {
        const latest = tags.find((t: any) => filter(t, major))?.name;
        if (latest && latest !== state.github[major]) {
          console.log(`NEW ${repo} VERSION for ${major}: ${latest}`);
          state.github[major] = latest;
          state.triggers.push(`github:${major}:${latest}`);
        }
      }
    } catch (e) {
      console.error(`Git tag check failed for ${repo}:`, e);
    }
  };

/**
 * Generic Docker Digest Checker Factory
 */
const createDockerChecker = (registry: string): Checker => 
  async (state, config) => {
    for (const tag of Object.keys(state.dockerhub)) {
      try {
        const response = await fetch(`https://hub.docker.com/v2/repositories/${registry}/tags/${tag}`);
        const data = await response.json();
        const current = data.images?.[0]?.digest;

        if (current && current !== state.dockerhub[tag]) {
          console.log(`NEW ${registry}:${tag} DIGEST: ${current}`);
          state.dockerhub[tag] = current;
          state.triggers.push(`dockerhub:${tag}`);
        }
      } catch (e) {
        console.error(`Docker digest check failed for ${registry}:${tag}:`, e);
      }
    }
  };

// Specialized Checkers
const checkMoodle = createGitChecker(MOODLE_UPSTREAM, (tag, major) => {
  const majorStr = `${major[0]}.${parseInt(major.slice(1))}`;
  return new RegExp(`^v${majorStr.replace('.', '\\.')}\\.\\d+`).test(tag.name);
});

const checkPhp = createDockerChecker("library/php");

/**
 * 4. Trigger GitHub Repository Dispatch
 */
async function triggerDispatch(state: State): Promise<boolean> {
  console.log(`Triggering GitHub build (Reasons: ${state.triggers.join(', ')})`);
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
          triggers: state.triggers,
          versions: {
            moodle: state.github,
            php: state.dockerhub,
            repo: state.repoTag
          }
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
  // 0. Reset triggers and deep clone state
  const newState: State = JSON.parse(JSON.stringify(state));
  newState.triggers = [];
  
  checkWebhookTrigger(newState);

  return fetchWorkflowConfig()
    .then(config => {
      if (!config) throw new Error("ConfigFetchFailed");
      
      // 1. Sync state with current workflow configuration
      syncState(newState, config);

      // 2. Run Checkers in Parallel
      const checkers: Checker[] = [checkMoodle, checkPhp];
      return Promise.all(checkers.map(check => check(newState, config)));
    })
    .then(() => {
      if (newState.triggers.length > 0) {
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
