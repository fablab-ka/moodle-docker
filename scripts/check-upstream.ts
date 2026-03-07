/**
 * Upstream Update Checker for Moodle & PHP
 *
 * This script checks for new Moodle tags and PHP image digest updates.
 * It is designed to be ran as a scheduled Komodo action or triggered via Webhook.
 */

// --- Configuration ---
const GITHUB_REPO = ARGS.REPO_NAME;
const GITHUB_TOKEN = ARGS.BUILD_TOKEN;

const MOODLE_UPSTREAM = ARGS.MOODLE_UPSTREAM;
const PHP_UPSTREAM = ARGS.PHP_UPSTREAM;

const KOMODO_VAR_KEY = ARGS.KOMODO_STATE_VARNAME;

// --- State & Config Interfaces ---
interface State {
  git: Record<string, Record<string, string>>;
  docker: Record<string, Record<string, string>>;
  repoTag?: string;
  triggers: string[];
  error?: any;
}

interface WorkflowConfig {
  moodleMajor: string;
  phpVersions: string[];
}

type Checker = (state: State) => Promise<State>;

/**
 * 0. Check for Webhook Trigger (moodle-docker repo)
 */
async function checkWebhookTrigger(state: State): Promise<State> {
  // @ts-ignore - ARGS is provided by Komodo runtime
  if (typeof ARGS !== 'undefined' && ARGS.WEBHOOK_BODY) {
    const payload = ARGS.WEBHOOK_BODY;
    if (payload.ref && payload.ref.startsWith('refs/tags/')) {
      const newTag = payload.ref.replace('refs/tags/', '');
      if (newTag !== '' && newTag !== state.repoTag) {
        console.log(`WEBHOOK: New tag detected in moodle-docker: ${newTag}`);
        state.repoTag = newTag;
        state.triggers.push(`repo:${newTag}`);
      }
    }
  }
  return state;
}

/**
 * 1. Fetch current publish.yml to get dynamic configuration
 */
async function fetchWorkflowConfig(): Promise<WorkflowConfig | null> {
  console.log("Fetching current configuration from main branch...");
  try {
    const url = `https://raw.githubusercontent.com/${GITHUB_REPO}/main/.github/workflows/publish.yml`;
    const res = await fetch(url);
    const yaml = await res.text();

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
  const syncForUpstream = (checker: string, upstream: string, versions: string[]) => {
    // @ts-ignore
    checker in state || (state[checker] = {});
    // @ts-ignore
    upstream in state[checker] || (state[checker][upstream] = {});

    // @ts-ignore
    Object.keys(state[checker][upstream]).forEach(sV => versions.includes(sV) || (delete state[checker][upstream][sV]));
    // @ts-ignore
    versions.forEach(cV => cV in state[checker][upstream] || (state[checker][upstream][cV] = ""));
  };

  syncForUpstream('git', MOODLE_UPSTREAM, [config.moodleMajor]);
  syncForUpstream('docker', PHP_UPSTREAM, config.phpVersions.map(v => `${v}-fpm`));
}

async function mergeConfigIntoState(obj: { state: State, config: WorkflowConfig }): Promise<State> {
  syncState(obj.state, obj.config);
  return obj.state;
}

/**
 * Generic Git Tag Checker Factory
 */
const createGitChecker = (repo: string, stateKey: keyof State, filter: (tag: any, config: WorkflowConfig, state: State) => boolean): Checker => 
  async (state) => {
    // Placeholder for factory logic to keep interfaces compatible for now
    return state;
  };

/**
 * Generic Docker Digest Checker Factory
 */
const createDockerChecker = (registry: string, stateKey: 'phpDigests'): Checker => 
  async (state) => {
    // Placeholder
    return state;
  };

// Specialized Checkers
const checkMoodle = createGitChecker(MOODLE_UPSTREAM, 'git', (tag, config) => true);
const checkPhp = createDockerChecker("library/php", 'docker' as any);

/**
 * 4. Trigger GitHub Repository Dispatch
 */
async function triggerDispatch(state: State): Promise<boolean> {
  console.log("Triggering GitHub workflow...");
  try {
    const res = await fetch(`https://api.github.com/repos/${GITHUB_REPO}/dispatches`, {
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
            ...(state.repoTag && { repo: state.repoTag }),
            ...state.git,
            ...state.docker
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
  const newState: State = JSON.parse(JSON.stringify(state));
  newState.triggers = [];
  
  return checkWebhookTrigger(newState)
    .then(fetchWorkflowConfig)
    .then(config => {
      if (!config) throw new Error("ConfigFetchFailed");
      return mergeConfigIntoState({ state: newState, config });
    })
    .then(state => {
      if (state.triggers.length > 0) {
        return triggerDispatch(state).then(success => {
          if (success) console.log("Build triggered successfully.");
          return state;
        });
      }
      console.log("No updates found.");
      return state;
    })
    .catch(err => {
      console.error("Pipeline error:", err);
      return state;
    });
}
