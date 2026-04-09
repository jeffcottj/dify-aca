#!/usr/bin/env sh
set -eu

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

random_b64() {
  length="$1"
  openssl rand -base64 "$length" | tr -d '\n'
}

set_if_missing() {
  key="$1"
  value="$2"
  current="$(printenv "$key" || true)"
  if [ -z "$current" ]; then
    azd env set "$key" "$value" >/dev/null
    export "$key=$value"
    echo "Initialized $key"
  fi
}

require_cmd azd
require_cmd az
require_cmd openssl

tenant_id="${ENTRA_TENANT_ID:-}"
if [ -z "$tenant_id" ]; then
  tenant_id="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
fi

set_if_missing DEPLOYMENT_PREFIX "dify"
set_if_missing POSTGRES_ADMIN_USERNAME "difyadmin"
set_if_missing POSTGRES_SKU_NAME "Standard_B1ms"
set_if_missing POSTGRES_SKU_TIER "Burstable"
set_if_missing POSTGRES_STORAGE_GB "32"
set_if_missing REDIS_SKU_NAME "Balanced_B0"

set_if_missing DIFY_API_IMAGE "langgenius/dify-api:1.13.3"
set_if_missing DIFY_WEB_IMAGE "langgenius/dify-web:1.13.3"
set_if_missing DIFY_SANDBOX_IMAGE "langgenius/dify-sandbox:0.2.14"
set_if_missing DIFY_PLUGIN_DAEMON_IMAGE "langgenius/dify-plugin-daemon:0.5.3-local"
set_if_missing GATEWAY_IMAGE "nginx:latest"
set_if_missing SSRF_PROXY_IMAGE "ubuntu/squid:latest"

set_if_missing ENABLE_CONSOLE_AUTH "false"
if [ -n "$tenant_id" ]; then
  set_if_missing ENTRA_TENANT_ID "$tenant_id"
fi

set_if_missing POSTGRES_ADMIN_PASSWORD "$(random_b64 32)"
set_if_missing DIFY_SECRET_KEY "sk-$(random_b64 36)"
set_if_missing DIFY_INIT_PASSWORD "$(random_b64 24)"
set_if_missing PLUGIN_DAEMON_KEY "$(random_b64 36)"
set_if_missing PLUGIN_DIFY_INNER_API_KEY "$(random_b64 36)"
set_if_missing SANDBOX_API_KEY "$(random_b64 24)"
set_if_missing CONSOLE_AUTH_SIGNING_KEY "$(random_b64 48)"
set_if_missing CONSOLE_AUTH_ENCRYPTION_KEY "$(random_b64 48)"

if [ "${ENABLE_CONSOLE_AUTH:-false}" = "true" ]; then
  if [ -z "${ENTRA_CLIENT_ID:-}" ]; then
    echo "ENABLE_CONSOLE_AUTH=true but ENTRA_CLIENT_ID is not set." >&2
    exit 1
  fi
  if [ -z "${ENTRA_CLIENT_SECRET:-}" ]; then
    echo "ENABLE_CONSOLE_AUTH=true but ENTRA_CLIENT_SECRET is not set." >&2
    exit 1
  fi
  if [ -z "${ENTRA_TENANT_ID:-}" ]; then
    echo "ENABLE_CONSOLE_AUTH=true but ENTRA_TENANT_ID is not set." >&2
    exit 1
  fi
fi

