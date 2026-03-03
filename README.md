# Moodle Docker Deployment (CI/CD Ready)

This is a professional-grade, multi-container Moodle deployment designed for ease of maintenance and stability. It is optimized for non-profit organizations using GitOps-ish-style deployments (e.g., Komodo).

## Architecture: Server-Worker Pattern

This setup uses a **shared custom image** for both the application and the background worker.

- **`app`**: Runs PHP-FPM to serve Moodle requests.
- **`cron`**: Runs the same image but executes the Moodle cron loop in a CLI environment.
- **`web`**: A Caddy server that serves static assets directly from the shared code volume and proxies PHP requests to `app`.
- **`db`**: A PostgreSQL database container.

### Key Features
- **Stateless Configuration**: `config.php` is generated dynamically from environment variables.
- **Automated Install/Upgrade**: The system automatically installs Moodle on an empty database or upgrades it if `MOODLE_AUTO_UPGRADE=true`.
- **Single Image Updates**: Updating the Moodle version is as simple as changing a single tag in your CI/CD pipeline or `.env` file.
- **Forced Settings**: Pre-configure any Moodle setting via environment variables and "lock" it from changes in the web UI.

## Configuration Overrides & Locking

You can override and "lock" settings directly from your `docker-compose.yml` or `.env` file using these prefixes:

### Core Settings (`MOODLE_CFG_`)
Core settings are automatically locked in the UI when defined.
- `MOODLE_CFG_theme=boost` -> Forces the 'boost' theme.
- `MOODLE_CFG_lang=de` -> Forces German language.
- `MOODLE_CFG_sessiontimeout=3600` -> Sets session timeout to 1 hour.

### Plugin Settings (`MOODLE_PLG_`)
Use the format `MOODLE_PLG_pluginname__settingname`. These are also automatically locked in the UI.
- `MOODLE_PLG_auth_ldap__host_url=ldaps://ldap.example.com` -> Forces the LDAP host.
- `MOODLE_PLG_quiz__grademethod=1` -> Forces the quiz grading method.

## Background Workers

The `cron` service handles both scheduled tasks and ad-hoc tasks. You can scale these via environment variables in your `docker-compose.yml`:

- **`MOODLE_CRON_COUNT`** (Default: 1): Number of parallel `cron.php` instances to run per minute. These use `--keep-alive=60` to manage internal locking.
- **`MOODLE_ADHOC_TASK_COUNT`** (Default: 0): Number of parallel `adhoc_task.php` instances to run per minute. These use `--keep-alive=59` for rapid task processing.

### Automating OAuth2 Issuers via CLI
Because OAuth2 "Issuers" are database-driven, they cannot be fully configured in `config.php`. We provide an idempotent helper script to manage them via JSON:

1.  **Prepare a JSON config** (see `scripts/oauth2-config.example.json`).
2.  **Run the script** inside the container:
    ```bash
    docker compose exec app php /var/www/html/scripts/manage_oauth2_issuer.php /path/to/your-config.json
    ```

This script will:
- Create the issuer if it doesn't exist (matched by name or baseurl).
- Update attributes (Client ID, Secret, etc.) if it already exists.
- Automatically synchronize endpoints via OIDC discovery.
- Idempotently manage user field mappings.

#### Automating via Environment Variables
Alternatively, you can provide the same JSON configuration directly via environment variables. Any variable starting with `MOODLE_OAUTH2_CONFIG_` will be processed on boot:

```yaml
# docker-compose.yml example
environment:
  MOODLE_OAUTH2_CONFIG_JSON: '{"name":"MyIDP","baseurl":"https://idp.example.com","clientid":"id","clientsecret":"secret","enabled":1,"field_mappings":{"sub":"username","email":"email"}}'
```

## CI/CD & Publishing

This repository includes a GitHub Actions workflow to automatically build and publish the Moodle image to the **GitHub Container Registry (GHCR)**.

### How to Publish
1.  **Automated**: Every push to the `main` branch or a version tag (e.g., `v5.1.3`) triggers a build.
2.  **Manual**: Go to the "Actions" tab in your GitHub repository and run the "Publish Moodle Image" workflow manually.

### Using the Published Image
To use the published image instead of building it locally, update your `docker-compose.yml`:

```yaml
services:
  app:
    image: ghcr.io/your-username/moodle-docker:latest
    # remove the 'build:' section
```

#### Available Tags
The image is published with the following tagging strategy:
- **`latest`**: Points to the most recent Moodle version on the latest PHP (8.4).
- **`lts`**: Points to the most recent Moodle version on the **LTS PHP** (8.2).
- **`<MAJOR>`** (e.g., `501`): Points to the most recent Moodle version of that major on the **LTS PHP** (8.2).
- **`<MAJOR>-php<VERSION>`** (e.g., `501-php8.3`): Points to a specific Moodle major on a specific PHP version (8.2, 8.3, or 8.4).

## Getting Started

1.  **Configure Environment**:
    ```bash
    cp .env.example .env
    # Edit .env with your specific settings (URL, DB passwords, etc.)
    ```

2.  **Launch**:
    ```bash
    docker-compose up -d --build
    ```

3.  **Initial Access**:
    Access your Moodle site at the URL specified in `MOODLE_URL`. The first boot will automatically run the installation.

## ⚠️ Security Warning

**CRITICAL**: The environment variables `MOODLE_ADMIN_USER`, `MOODLE_ADMIN_PASS`, and `MOODLE_ADMIN_EMAIL` are only used for the **initial installation**. Once the site is up and you have logged in, **remove these variables** from your `.env` file or CI/CD secrets to prevent accidental resets or credential exposure.

## Maintenance & Upgrades

### Updating Moodle
To update to a new Moodle version:
1.  Update `MOODLE_VERSION` in your `.env` file.
2.  Set `MOODLE_AUTO_UPGRADE=true`.
3.  Rebuild and restart:
    ```bash
    docker-compose up -d --build
    ```
4.  Once the upgrade is complete, set `MOODLE_AUTO_UPGRADE=false`.

### Reverse Proxy Support
If you are running behind a public-facing reverse proxy (e.g., Traefik, Nginx, Cloudflare):
- Set `MOODLE_REVERSE_PROXY=true`.
- If your proxy provides SSL, set `MOODLE_SSL_PROXY=true`.

## Volumes
- `moodle_code`: Persistent Moodle source code (shared between Caddy and PHP).
- `moodle_data`: The `moodledata` directory for uploads and cache.
- `db_data`: Persistent PostgreSQL data.
