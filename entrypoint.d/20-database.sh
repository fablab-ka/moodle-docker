#!/bin/bash
set -e

# Wait for DB to be ready
echo "Waiting for database to be ready..."
MAX_RETRIES=30
[ "$IS_WORKER" = "true" ] && MAX_RETRIES=60 # Workers wait longer
RETRY_COUNT=0
until php -r "try { new PDO('pgsql:host=' . (getenv('MOODLE_DB_HOST') ?: 'db') . ';port=' . (getenv('MOODLE_DB_PORT') ?: '5432') . ';dbname=' . (getenv('MOODLE_DB_NAME') ?: 'moodle'), getenv('MOODLE_DB_USER') ?: 'moodle', getenv('MOODLE_DB_PASS') ?: 'moodle'); exit(0); } catch (Exception \$e) { exit(1); }"; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "ERROR: Database connection timed out."
    exit 1
  fi
  echo "Database not ready yet... ($RETRY_COUNT/$MAX_RETRIES)"
  sleep 2
done
echo "Database is ready."
