#!/usr/bin/env sh
set -eu

require_env() {
  key="$1"
  value="$(printenv "$key" || true)"
  if [ -z "$value" ]; then
    echo "Missing required environment variable after provision: $key" >&2
    exit 1
  fi
}

if [ "${SKIP_VECTOR_BOOTSTRAP:-false}" = "true" ]; then
  echo "Skipping pgvector bootstrap because SKIP_VECTOR_BOOTSTRAP=true"
  exit 0
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI is required for the postprovision hook." >&2
  exit 1
fi

require_env RESOURCE_GROUP_NAME
require_env POSTGRES_SERVER_NAME
require_env POSTGRES_ADMIN_USERNAME
require_env POSTGRES_ADMIN_PASSWORD
require_env DIFY_DATABASE_NAME

echo "Ensuring pgvector extension exists in ${DIFY_DATABASE_NAME} on ${POSTGRES_SERVER_NAME}"

az postgres flexible-server execute \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --name "$POSTGRES_SERVER_NAME" \
  --admin-user "$POSTGRES_ADMIN_USERNAME" \
  --admin-password "$POSTGRES_ADMIN_PASSWORD" \
  --database-name "$DIFY_DATABASE_NAME" \
  --querytext "CREATE EXTENSION IF NOT EXISTS vector;" \
  --output none

echo "pgvector bootstrap complete"
