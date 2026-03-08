# Moodle Docker Deployment (CI/CD Ready)

This is a professional-grade, multi-container Moodle deployment designed for ease of maintenance and stability. It is optimized for non-profit organizations using GitOps-ish-style deployments (e.g., Komodo).

## Architecture: Server-Worker Pattern

This setup uses a **shared custom image** for the PHP-based services.

- **`app`**: Runs PHP-FPM to serve Moodle requests.
- **`cron`**: Runs the same image but executes the Moodle cron and ad-hoc task loop.
- **`web`**: A standard Caddy server that serves static assets from the shared code volume and proxies PHP requests to `app`.
- **`db`**: A PostgreSQL database container.

### Key Features
- **Stateless Configuration**: `config.php` is generated dynamically from environment variables on boot.
- **Modular Entrypoint**: Uses `run-parts` to execute idempotent step scripts in `/docker-entrypoint.d/`.
- **Patched Source**: Moodle core code is patched during the build process.
- **Forced Settings**: Pre-configure any Moodle setting via `MOODLE_CFG_` or `MOODLE_PLG_` environment variables.

## Getting Started

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
By default, the image is the "Source of Truth" for Moodle core. Every time the `app` container starts, it synchronizes its patched code from `/opt/moodle/code` to the shared `moodle_code` volume using `rsync --delete`.

### Adding Persistent Plugins/Themes
If you need to persist specific plugins or themes via volumes:
1.  **Mount the volume** in `docker-compose.yml` (e.g., `- ./my_theme:/var/www/html/theme/my_theme`).
2.  **Exclude it from sync** by adding it to the `MOODLE_DOCKER_SYNC_EXCLUDE` environment variable (e.g., `MOODLE_DOCKER_SYNC_EXCLUDE="mod/my_plugin theme/my_theme"`).

**WARNING**: If you mount a volume but forget to add it to the exclude list, `rsync` will attempt to delete or overwrite the files inside that volume on every boot.

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
