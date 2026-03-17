# Moodle Docker Deployment (CI/CD Ready)

This is a professional-grade, multi-container Moodle deployment designed for ease of maintenance and stability. It is optimized for non-profit organizations using GitOps-ish-style deployments (e.g., Komodo).

## Architecture: Server-Worker Pattern

This setup uses a **shared custom image** for the PHP-based services.

- **`app`**: Runs PHP-FPM to serve Moodle requests.
- **`cron`**: Runs the same image but executes the Moodle cron and ad-hoc task loop.
- **`web`**: A standard Caddy server that serves static assets from the shared code volume and proxies PHP requests to `app`.
- **`db`**: A PostgreSQL database container.

### Key Features
- **Stateless Architecture**: The `/var/www/html` directory is ephemeral and wiped on every container restart, ensuring a "clean slate" and preventing configuration drift.
- **Declarative Plugin Management**: Define plugins in your environment variables via `MOODLE_PLUGINS`, and they are automatically installed on boot using **Moosh**.
- **Stateless Configuration**: `config.php` is baked into the image and reads all settings from environment variables.
- **Modular Entrypoint**: Uses `run-parts` to execute idempotent step scripts in `/docker-entrypoint.d/`.
- **Patched Source**: Moodle core code is patched during the build process.
- **Forced Settings**: Pre-configure any Moodle setting via `MOODLE_CFG_` or `MOODLE_PLG_` environment variables. String values "true" and "false" (case-insensitive) are automatically converted to their boolean equivalents.

## Getting Started
...
### Custom Configuration
For complex configuration values (like arrays or objects) that cannot be easily passed via environment variables, you can provide a `config-custom.php` file. 

1. Create a `config-custom.php` file in your project root.
2. Mount it into the container in your `docker-compose.yml`:
   ```yaml
   services:
     app:
       volumes:
         - ./config-custom.php:/opt/moodle/config-custom.php
   ```

This file will be included by the main `config.php` before the final Moodle setup is executed.

1.  **Configure Environment**:
    ```bash
    cp .env.example .env
    # Edit .env with your specific settings
    ```

2.  **Launch**:
    ```bash
    docker-compose up -d
    ```

3.  **Initial Access**:
    Access your Moodle site at the URL specified in `MOODLE_URL`. The first boot will automatically run the installation.

**Security Warning**: The environment variables `MOODLE_ADMIN_USER`, `MOODLE_ADMIN_PASS`, and `MOODLE_ADMIN_EMAIL` are only used for the **initial installation**. Once the site is up and you have logged in, remove these variables from your `.env` file or CI/CD secrets to prevent accidental resets or credential exposure.

### Local Development (In-place Build)
If you wish to build the image locally instead of pulling from GHCR, modify your `docker-compose.yml`:
1.  Comment out the `image: ghcr.io/...` lines for `app` and `cron`.
2.  Uncomment the `build:` blocks.
3.  Run: `docker-compose up -d --build`

## Configuration Overrides & Locking

You can override and "lock" settings directly from your `docker-compose.yml` or `.env` file using these prefixes:

### Core Settings (`MOODLE_CFG_`)
Core settings are automatically locked in the UI when defined.
- `MOODLE_CFG_theme=boost` -> Forces the 'boost' theme.
- `MOODLE_CFG_lang=de` -> Forces German language.
- `MOODLE_CFG_smtphosts=smtp.example.com:587` -> Sets the SMTP server.

### Plugin Settings (`MOODLE_PLG_`)
Use the format `MOODLE_PLG_pluginname__settingname`. These are also automatically locked in the UI.
- `MOODLE_PLG_auth_ldap__host_url=ldaps://ldap.example.com` -> Forces the LDAP host.

## Background Workers

The `cron` service handles both scheduled tasks and ad-hoc tasks. You can scale these via environment variables:

- **`MOODLE_CRON_COUNT`** (Default: 1): Parallel `cron.php` instances.
- **`MOODLE_ADHOC_TASK_COUNT`** (Default: 0): Parallel `adhoc_task.php` instances.

### Automating OAuth2 Issuers via CLI
We provide an idempotent helper script to manage issuers via JSON:

1.  **Prepare a JSON config** (see `scripts/oauth2-config.example.json`).
2.  **Run the script** inside the container:
    ```bash
    docker compose exec app php /opt/moodle/scripts/manage_oauth2_issuer.php /path/to/your-config.json
    ```

#### Automating via Environment Variables
Alternatively, any variable starting with `MOODLE_OAUTH2_CONFIG_` will be processed on boot:

```yaml
environment:
  MOODLE_OAUTH2_CONFIG_JSON: '{"name":"MyIDP",...}'
```

## Advanced Customization

### Stateless Code & Sync
In this architecture, the container's `/opt/moodle/code` directory is the **Source of Truth**. Every time the `app` (Leader) container starts, it:
1.  **Restores** the patched core code from the image to the shared volume (using `rsync --delete`).
2.  **Performs** Moodle installation or upgrades (Scripts 20-40).
3.  **Installs** any plugins defined in `MOODLE_PLUGINS` (Script 50).
4.  **Signals Readiness** via a `.ready` file (Script 99).

Follower services (`cron`, `web`) will wait for this `.ready` signal before starting their main processes. This ensures they only run when the codebase is fully synchronized and plugins are installed.

### Declarative Plugin Management
Instead of manually uploading plugins, define them in your `docker-compose.yml`:

```yaml
environment:
  MOODLE_PLUGINS: "theme_moove mod_checklist https://github.com/example/plugin/archive/master.zip"
  MOODLE_AUTO_UPGRADE: "true"
```

Plugins can be specified by their Moodle directory name (e.g., `theme_moove`) or by a direct download URL. The entrypoint uses **Moosh** to download and install them automatically.

**Note**: It is highly recommended to set `MOODLE_AUTO_UPGRADE=true` when using `MOODLE_PLUGINS` to ensure that any database migrations required by the new plugins are executed automatically on boot.

#### Optional Download Cache
To speed up container startups and reduce network load, you can mount a persistent volume for the plugin cache. This will store `plugins.json` and all downloaded ZIP artifacts.

```yaml
volumes:
  - moodle_plugincache:/var/www/plugincache
```

When enabled, the system will transparently reuse cached ZIP files, allowing Moosh to perform near-instant local installations.

**WARNING**: Any files manually added to `/var/www/html` (e.g., via the Moodle UI or manual upload) **will be deleted** on the next container restart. Always use `MOODLE_PLUGINS` for persistent plugin management.

## CI/CD & Publishing

### Available Tags
- **`latest`**: Most recent Moodle on PHP 8.4.
- **`lts`**: Most recent Moodle on PHP 8.2 (LTS).
- **`<MAJOR>`** (e.g., `501`): Most recent Moodle of that major on LTS PHP (8.2).
- **`<MAJOR>-php<VERSION>`**: Specific versions (e.g., `501-php8.3`).

## Maintenance & Upgrades

### Updating Moodle
To update, simply change the image tag or `MOODLE_VERSION` and restart.

### Reverse Proxy Support
If you are running behind a public-facing reverse proxy (e.g., Traefik, Nginx, Cloudflare):
- Set `MOODLE_REVERSE_PROXY=true`.
- If your proxy provides SSL, set `MOODLE_SSL_PROXY=true`.

## Volumes
- `moodle_code`: Shared Moodle source code volume (managed by app sync).
- `moodle_data`: The `moodledata` directory for uploads and cache.
- `db_data`: Persistent PostgreSQL data.
