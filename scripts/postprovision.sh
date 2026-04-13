#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
HOOK_CACHE_DIR="${SCRIPT_DIR}/../.azure/hooks"
PYTHON_VENV_DIR="${HOOK_CACHE_DIR}/pg-bootstrap-venv"
FIREWALL_API_VERSION="2024-08-01"

require_env() {
  key="$1"
  value="$(printenv "$key" || true)"
  if [ -z "$value" ]; then
    echo "Missing required environment variable after provision: $key" >&2
    exit 1
  fi
}

require_cmd() {
  cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command for postprovision hook: $cmd" >&2
    exit 1
  fi
}

get_public_ip() {
  if [ -n "${POSTPROVISION_PUBLIC_IP:-}" ]; then
    printf '%s' "$POSTPROVISION_PUBLIC_IP"
    return 0
  fi

  curl -fsS https://api.ipify.org 2>/dev/null ||
    curl -fsS https://ifconfig.me/ip 2>/dev/null ||
    return 1
}

prepare_python_client() {
  mkdir -p "$HOOK_CACHE_DIR"

  if [ ! -x "${PYTHON_VENV_DIR}/bin/python" ]; then
    echo "Preparing cached Python PostgreSQL client in ${PYTHON_VENV_DIR}"
    rm -rf "$PYTHON_VENV_DIR"
    python3 -m venv "$PYTHON_VENV_DIR"
  fi

  if ! "${PYTHON_VENV_DIR}/bin/python" -c 'import psycopg' >/dev/null 2>&1; then
    echo "Installing psycopg client into ${PYTHON_VENV_DIR}"
    "${PYTHON_VENV_DIR}/bin/pip" install --disable-pip-version-check -q 'psycopg[binary]'
  fi
}

if [ "${SKIP_VECTOR_BOOTSTRAP:-false}" = "true" ]; then
  echo "Skipping pgvector bootstrap because SKIP_VECTOR_BOOTSTRAP=true"
  exit 0
fi

require_cmd az
require_cmd curl
require_cmd python3
require_env AZURE_ENV_NAME
require_env AZURE_SUBSCRIPTION_ID
require_env RESOURCE_GROUP_NAME
require_env POSTGRES_SERVER_FQDN
require_env POSTGRES_SERVER_NAME
require_env POSTGRES_ADMIN_USERNAME
require_env POSTGRES_ADMIN_PASSWORD
require_env DIFY_DATABASE_NAME

public_ip="$(get_public_ip || true)"
if [ -z "$public_ip" ]; then
  echo "Could not determine a public IP address for PostgreSQL bootstrap. Set POSTPROVISION_PUBLIC_IP to override." >&2
  exit 1
fi

prepare_python_client

echo "Ensuring pgvector extension exists in ${DIFY_DATABASE_NAME} on ${POSTGRES_SERVER_NAME}"
echo "Temporarily allowing PostgreSQL access from ${public_ip}"

env_token="$(printf '%s' "$AZURE_ENV_NAME" | tr -c '[:alnum:]_-' '-')"
firewall_rule_name="postprovision-${env_token}-$$-$(date +%s)"
firewall_rule_url="https://management.azure.com/subscriptions/${AZURE_SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP_NAME}/providers/Microsoft.DBforPostgreSQL/flexibleServers/${POSTGRES_SERVER_NAME}/firewallRules/${firewall_rule_name}?api-version=${FIREWALL_API_VERSION}"
firewall_rule_body="$(printf '{"properties":{"startIpAddress":"%s","endIpAddress":"%s"}}' "$public_ip" "$public_ip")"

cleanup() {
  if [ -n "${firewall_rule_url:-}" ]; then
    az rest --method delete --url "$firewall_rule_url" --output none >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

az rest --method put --url "$firewall_rule_url" --body "$firewall_rule_body" --output none

attempt=0
while [ "$attempt" -lt 30 ]; do
  current_ip="$(az rest --method get --url "$firewall_rule_url" --query 'properties.startIpAddress' --output tsv 2>/dev/null || true)"
  if [ "$current_ip" = "$public_ip" ]; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done

if [ "${current_ip:-}" != "$public_ip" ]; then
  echo "Timed out waiting for temporary PostgreSQL firewall rule ${firewall_rule_name} to become active." >&2
  exit 1
fi

POSTGRES_SERVER_FQDN="$POSTGRES_SERVER_FQDN" \
POSTGRES_ADMIN_USERNAME="$POSTGRES_ADMIN_USERNAME" \
POSTGRES_ADMIN_PASSWORD="$POSTGRES_ADMIN_PASSWORD" \
DIFY_DATABASE_NAME="$DIFY_DATABASE_NAME" \
"${PYTHON_VENV_DIR}/bin/python" - <<'PY'
import os

import psycopg

with psycopg.connect(
    host=os.environ["POSTGRES_SERVER_FQDN"],
    dbname=os.environ["DIFY_DATABASE_NAME"],
    user=os.environ["POSTGRES_ADMIN_USERNAME"],
    password=os.environ["POSTGRES_ADMIN_PASSWORD"],
    sslmode="require",
    connect_timeout=10,
) as conn:
    with conn.cursor() as cur:
        cur.execute("CREATE EXTENSION IF NOT EXISTS vector;")
PY

echo "pgvector bootstrap complete"
