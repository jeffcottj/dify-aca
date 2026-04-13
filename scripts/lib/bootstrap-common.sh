#!/usr/bin/env sh

if [ -n "${DIFY_BOOTSTRAP_COMMON_SH:-}" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi
DIFY_BOOTSTRAP_COMMON_SH=1

BOOTSTRAP_DEFAULT_LOCATION="eastus"

bootstrap_info() {
  printf '%s\n' "$*"
}

bootstrap_warn() {
  printf 'Warning: %s\n' "$*" >&2
}

bootstrap_error() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

bootstrap_require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    bootstrap_error "Missing required command: $1"
  fi
}

bootstrap_env_exists() {
  env_name="$1"
  [ -n "$env_name" ] || return 1
  if [ -f ".azure/$env_name/.env" ]; then
    return 0
  fi
  azd env list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -Fx "$env_name" >/dev/null 2>&1
}

bootstrap_allow_explicit_blank() {
  case "$1" in
    DIFY_INIT_PASSWORD) return 0 ;;
    *) return 1 ;;
  esac
}

bootstrap_env_key_is_explicitly_blank() {
  key="$1"
  env_name="$2"

  bootstrap_allow_explicit_blank "$key" || return 1
  [ -n "$env_name" ] || return 1

  env_file=".azure/$env_name/.env"
  [ -f "$env_file" ] || return 1

  line="$(grep -E "^${key}=" "$env_file" | tail -n 1)"
  case "$line" in
    "$key="|"$key=\"\""|"$key=''" )
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_env_read() {
  key="$1"
  env_name="${2:-}"

  eval "value=\${$key-}"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  if [ -n "$env_name" ]; then
    if ! bootstrap_env_exists "$env_name"; then
      return 0
    fi
    if value="$(azd env get-value "$key" -e "$env_name" 2>/dev/null)"; then
      printf '%s' "$value"
    fi
    return 0
  fi

  printenv "$key" 2>/dev/null || true
}

bootstrap_export_value() {
  key="$1"
  value="$2"
  export "$key=$value"
}

bootstrap_env_set() {
  env_name="$1"
  key="$2"
  value="$3"

  azd env set -e "$env_name" "$key" "$value" >/dev/null
  bootstrap_export_value "$key" "$value"
}

bootstrap_set_if_missing() {
  env_name="$1"
  key="$2"
  value="$3"

  current="$(bootstrap_env_read "$key" "$env_name")"
  if [ -n "$current" ]; then
    bootstrap_export_value "$key" "$current"
    return 1
  fi

  if bootstrap_env_key_is_explicitly_blank "$key" "$env_name"; then
    bootstrap_export_value "$key" ''
    return 1
  fi

  bootstrap_env_set "$env_name" "$key" "$value"
  return 0
}

bootstrap_random_b64() {
  length="$1"
  openssl rand -base64 "$length" | tr -d '\n'
}

bootstrap_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

bootstrap_normalize_bool() {
  case "$(bootstrap_lower "$1")" in
    1|y|yes|true)
      printf 'true'
      ;;
    *)
      printf 'false'
      ;;
  esac
}

bootstrap_trim_to() {
  limit="$1"
  value="$2"
  printf '%s' "$value" | cut -c "1-$limit"
}

bootstrap_normalize_token() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '._' '--'
}

bootstrap_strip_dashes() {
  printf '%s' "$1" | tr -d '-'
}

bootstrap_guess_tenant_id() {
  tenant_id="$(bootstrap_env_read ENTRA_TENANT_ID "${1:-}")"
  if [ -n "$tenant_id" ]; then
    printf '%s' "$tenant_id"
    return 0
  fi

  az account show --query tenantId -o tsv 2>/dev/null || true
}

bootstrap_subscription_has_location() {
  subscription_id="$1"
  location_name="$2"

  result="$(
    az rest \
      --method get \
      --url "https://management.azure.com/subscriptions/$subscription_id/locations?api-version=2022-12-01" \
      --query "value[?type=='Region' && name=='$location_name'].name" \
      -o tsv 2>/dev/null
  )" || return 2

  printf '%s\n' "$result" | grep -Fx "$location_name" >/dev/null 2>&1
}

bootstrap_default_keys() {
  cat <<'EOF'
DEPLOYMENT_PREFIX
POSTGRES_ADMIN_USERNAME
POSTGRES_SKU_NAME
POSTGRES_SKU_TIER
POSTGRES_STORAGE_GB
REDIS_SKU_NAME
DIFY_API_IMAGE
DIFY_WEB_IMAGE
DIFY_SANDBOX_IMAGE
DIFY_PLUGIN_DAEMON_IMAGE
GATEWAY_IMAGE
SSRF_PROXY_IMAGE
ENABLE_CONSOLE_AUTH
EOF
}

bootstrap_generated_secret_keys() {
  cat <<'EOF'
POSTGRES_ADMIN_PASSWORD
DIFY_SECRET_KEY
DIFY_INIT_PASSWORD
PLUGIN_DAEMON_KEY
PLUGIN_DIFY_INNER_API_KEY
SANDBOX_API_KEY
CONSOLE_AUTH_SIGNING_KEY
CONSOLE_AUTH_ENCRYPTION_KEY
EOF
}

bootstrap_default_for_key() {
  case "$1" in
    DEPLOYMENT_PREFIX) printf 'dify' ;;
    POSTGRES_ADMIN_USERNAME) printf 'difyadmin' ;;
    POSTGRES_SKU_NAME) printf 'Standard_B1ms' ;;
    POSTGRES_SKU_TIER) printf 'Burstable' ;;
    POSTGRES_STORAGE_GB) printf '32' ;;
    REDIS_SKU_NAME) printf 'Balanced_B0' ;;
    DIFY_API_IMAGE) printf 'langgenius/dify-api:1.13.3' ;;
    DIFY_WEB_IMAGE) printf 'langgenius/dify-web:1.13.3' ;;
    DIFY_SANDBOX_IMAGE) printf 'langgenius/dify-sandbox:0.2.14' ;;
    DIFY_PLUGIN_DAEMON_IMAGE) printf 'langgenius/dify-plugin-daemon:0.5.3-local' ;;
    GATEWAY_IMAGE) printf 'nginx:latest' ;;
    SSRF_PROXY_IMAGE) printf 'ubuntu/squid:latest' ;;
    ENABLE_CONSOLE_AUTH) printf 'false' ;;
    AZURE_LOCATION) printf '%s' "$BOOTSTRAP_DEFAULT_LOCATION" ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_help_for_key() {
  case "$1" in
    AZURE_SUBSCRIPTION_ID)
      cat <<'EOF'
Subscription used for the azd environment. It is optional only because azd can prompt for it later, but setting it here makes preview and deploy fully non-interactive.

Use the current default subscription unless you intentionally want this environment deployed elsewhere.
EOF
      ;;
    AZURE_LOCATION)
      cat <<'EOF'
Primary Azure region for every resource in this environment. The default is eastus because it is widely available, but you should override it when latency, compliance, or quota availability point to a different region.
EOF
      ;;
    DEPLOYMENT_PREFIX)
      cat <<'EOF'
Short word added to Azure resource names for this deployment. The default is "dify", so names stay readable and easy to recognize.

Example: if the prefix is "dify" and the environment is "prod", resource names will start with values like "dify-prod-...".

Change it when you want a team name, project name, or another label that helps distinguish this deployment from other Azure resources in the same subscription.
EOF
      ;;
    POSTGRES_ADMIN_USERNAME)
      cat <<'EOF'
Administrator login for the PostgreSQL flexible server. The default "difyadmin" is reasonable for most deployments because the actual password is generated separately.

Override it only if you have a naming standard or need to align with an operator convention.
EOF
      ;;
    POSTGRES_SKU_NAME)
      cat <<'EOF'
PostgreSQL compute SKU. The default "Standard_B1ms" is a low-cost starting point for experiments and small validation environments.

Override it when you need more CPU or memory, or when this SKU is not available in your region.
EOF
      ;;
    POSTGRES_SKU_TIER)
      cat <<'EOF'
PostgreSQL pricing tier. The default "Burstable" matches the low-cost starter SKU.

Override it only when you intentionally move to a General Purpose or higher class deployment.
EOF
      ;;
    POSTGRES_STORAGE_GB)
      cat <<'EOF'
Allocated PostgreSQL storage in GiB. The default 32 GiB is enough for basic evaluation.

Increase it when you expect larger datasets, higher WAL growth, or simply want more headroom before auto-grow expands the server.
EOF
      ;;
    REDIS_SKU_NAME)
      cat <<'EOF'
Azure Managed Redis SKU. The default "Balanced_B0" is the lowest-cost sensible baseline for queue/cache validation.

Override it when region availability, throughput, or memory requirements push you to a larger SKU.
EOF
      ;;
    DIFY_API_IMAGE|DIFY_WEB_IMAGE|DIFY_SANDBOX_IMAGE|DIFY_PLUGIN_DAEMON_IMAGE|GATEWAY_IMAGE|SSRF_PROXY_IMAGE)
      cat <<'EOF'
Container image override. These values are optional because the repo already carries tested defaults.

Only override them when you need a newer upstream release, a pinned private image, or a custom build for debugging.
EOF
      ;;
    ENABLE_CONSOLE_AUTH)
      cat <<'EOF'
Controls whether Azure Container Apps built-in auth protects the console gateway. Leave it false unless you have completed the Entra branch in the bootstrap flow.
EOF
      ;;
    ENTRA_TENANT_ID)
      cat <<'EOF'
Tenant used by the console auth configuration. This repo's current Container Apps auth setup is single-tenant, so the tenant ID must match the Entra app registration you use for console sign-in.
EOF
      ;;
    ENTRA_CLIENT_ID)
      cat <<'EOF'
Application (client) ID for the Entra app registration used by console sign-in. Optional only because console auth itself is optional.
EOF
      ;;
    ENTRA_CLIENT_SECRET)
      cat <<'EOF'
Client secret for the Entra app registration used by console sign-in. Optional only because console auth itself is optional.
EOF
      ;;
    BOOTSTRAP_PENDING_CONSOLE_AUTH)
      cat <<'EOF'
Internal flag used by the bootstrap script to remember that console auth should be enabled after the first deployment reveals CONSOLE_URL.
EOF
      ;;
    *)
      cat <<'EOF'
No additional help is available for this setting.
EOF
      ;;
  esac
}

bootstrap_generated_secret_value() {
  case "$1" in
    POSTGRES_ADMIN_PASSWORD) bootstrap_random_b64 32 ;;
    DIFY_SECRET_KEY) printf 'sk-%s' "$(bootstrap_random_b64 36)" ;;
    DIFY_INIT_PASSWORD) bootstrap_random_b64 24 ;;
    PLUGIN_DAEMON_KEY) bootstrap_random_b64 36 ;;
    PLUGIN_DIFY_INNER_API_KEY) bootstrap_random_b64 36 ;;
    SANDBOX_API_KEY) bootstrap_random_b64 24 ;;
    CONSOLE_AUTH_SIGNING_KEY) bootstrap_random_b64 48 ;;
    CONSOLE_AUTH_ENCRYPTION_KEY) bootstrap_random_b64 48 ;;
    *)
      return 1
      ;;
  esac
}

bootstrap_apply_default_values() {
  env_name="$1"

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    bootstrap_set_if_missing "$env_name" "$key" "$(bootstrap_default_for_key "$key")" || true
  done <<EOF
$(bootstrap_default_keys)
EOF

  tenant_id="$(bootstrap_guess_tenant_id "$env_name")"
  if [ -n "$tenant_id" ]; then
    bootstrap_set_if_missing "$env_name" ENTRA_TENANT_ID "$tenant_id" || true
  fi
}

bootstrap_apply_generated_secrets() {
  env_name="$1"

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    bootstrap_set_if_missing "$env_name" "$key" "$(bootstrap_generated_secret_value "$key")" || true
  done <<EOF
$(bootstrap_generated_secret_keys)
EOF
}

bootstrap_validate_console_auth_inputs() {
  enabled="$(bootstrap_normalize_bool "$(bootstrap_env_read ENABLE_CONSOLE_AUTH "${1:-}")")"
  if [ "$enabled" != "true" ]; then
    return 0
  fi

  if [ -z "$(bootstrap_env_read ENTRA_CLIENT_ID "${1:-}")" ]; then
    bootstrap_error "ENABLE_CONSOLE_AUTH=true but ENTRA_CLIENT_ID is not set."
  fi

  if [ -z "$(bootstrap_env_read ENTRA_CLIENT_SECRET "${1:-}")" ]; then
    bootstrap_error "ENABLE_CONSOLE_AUTH=true but ENTRA_CLIENT_SECRET is not set."
  fi

  if [ -z "$(bootstrap_env_read ENTRA_TENANT_ID "${1:-}")" ]; then
    bootstrap_error "ENABLE_CONSOLE_AUTH=true but ENTRA_TENANT_ID is not set."
  fi
}

bootstrap_render_name_preview() {
  env_name="$1"
  prefix="$2"

  env_token="$(bootstrap_normalize_token "$env_name")"
  prefix_token="$(bootstrap_normalize_token "$prefix")"
  short_unique='xxxxxx'
  name_prefix="$(bootstrap_trim_to 20 "${prefix_token}-${env_token}")"

  printf 'Normalized environment token: %s\n' "$env_token"
  printf 'Normalized prefix token: %s\n' "$prefix_token"
  printf 'Console gateway app: %s\n' "$(bootstrap_trim_to 32 "${name_prefix}-console")"
  printf 'Public gateway app: %s\n' "$(bootstrap_trim_to 32 "${name_prefix}-public")"
  printf 'Managed environment: %s\n' "$(bootstrap_trim_to 32 "${prefix_token}-${env_token}-${short_unique}-acae")"
  printf 'PostgreSQL server: %s\n' "$(bootstrap_trim_to 63 "${prefix_token}-${env_token}-${short_unique}-pg")"
  printf 'Key Vault: %s\n' "$(bootstrap_trim_to 24 "${prefix_token}-${env_token}-${short_unique}-kv")"
  printf 'Storage account: %s\n' "$(bootstrap_trim_to 24 "$(bootstrap_strip_dashes "${prefix_token}${env_token}${short_unique}st")")"
}

bootstrap_preview_truncation_warnings() {
  env_name="$1"
  prefix="$2"

  env_token="$(bootstrap_normalize_token "$env_name")"
  prefix_token="$(bootstrap_normalize_token "$prefix")"
  combined="${prefix_token}-${env_token}"
  storage_seed="$(bootstrap_strip_dashes "${prefix_token}${env_token}xxxxxxst")"

  if [ "${#combined}" -gt 20 ]; then
    bootstrap_warn "The combined prefix and environment token exceeds 20 characters, so Container App base names will be truncated."
  fi

  if [ "${#storage_seed}" -gt 24 ]; then
    bootstrap_warn "The derived storage account name exceeds 24 characters, so it will be truncated."
  fi
}
