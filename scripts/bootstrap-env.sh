#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/bootstrap-common.sh
. "$SCRIPT_DIR/lib/bootstrap-common.sh"

usage() {
  cat <<'EOF'
Usage: sh scripts/bootstrap-env.sh [-e <environment>]

Interactive bootstrap for configuring an azd environment for this repo.
EOF
}

ENVIRONMENT_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -e)
      [ "$#" -ge 2 ] || bootstrap_error "Missing value for -e"
      ENVIRONMENT_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      bootstrap_error "Unknown argument: $1"
      ;;
  esac
done

SUMMARY_FILE=$(mktemp "${TMPDIR:-/tmp}/dify-bootstrap-summary.XXXXXX")
trap 'rm -f "$SUMMARY_FILE"' EXIT HUP INT TERM

record_summary() {
  key="$1"
  status="$2"
  value="$3"
  printf '%s|%s|%s\n' "$key" "$status" "$value" >> "$SUMMARY_FILE"
}

render_summary() {
  bootstrap_info ""
  bootstrap_info "Environment summary:"
  bootstrap_info "--------------------"
  while IFS='|' read -r key status value; do
    printf '  %-30s %-14s %s\n' "$key" "$status" "$value"
  done < "$SUMMARY_FILE"
}

prompt_value() {
  label="$1"
  default_value="$2"
  help_text="$3"
  allow_empty="${4:-false}"

  while :; do
    if [ -n "$default_value" ]; then
      printf '%s [%s] (? for help): ' "$label" "$default_value" >&2
    elif [ "$allow_empty" = "true" ]; then
      printf '%s [optional] (? for help): ' "$label" >&2
    else
      printf '%s [required] (? for help): ' "$label" >&2
    fi

    IFS= read -r answer || exit 1
    case "$answer" in
      '?')
        bootstrap_info "" >&2
        bootstrap_info "$help_text" >&2
        bootstrap_info "" >&2
        ;;
      '')
        if [ -n "$default_value" ]; then
          printf '%s' "$default_value"
          return 0
        fi
        if [ "$allow_empty" = "true" ]; then
          printf '%s' ""
          return 0
        fi
        bootstrap_warn "A value is required."
        ;;
      *)
        printf '%s' "$answer"
        return 0
        ;;
    esac
  done
}

prompt_yes_no() {
  label="$1"
  default_answer="$2"
  help_text="${3:-}"

  while :; do
    if [ "$default_answer" = "yes" ]; then
      printf '%s [Y/n/?]: ' "$label" >&2
    else
      printf '%s [y/N/?]: ' "$label" >&2
    fi

    IFS= read -r answer || exit 1
    case "$answer" in
      '')
        answer="$default_answer"
        ;;
      '?')
        if [ -n "$help_text" ]; then
          bootstrap_info "" >&2
          bootstrap_info "$help_text" >&2
          bootstrap_info "" >&2
        fi
        continue
        ;;
      [Yy]|[Yy][Ee][Ss])
        answer="yes"
        ;;
      [Nn]|[Nn][Oo])
        answer="no"
        ;;
      *)
        bootstrap_warn "Please answer yes, no, or ?."
        continue
        ;;
    esac

    [ "$answer" = "yes" ]
    return $?
  done
}

prompt_secret_value() {
  label="$1"
  keep_existing="$2"
  help_text="$3"

  while :; do
    if [ "$keep_existing" = "true" ]; then
      printf '%s [press Enter to keep current, ? for help]: ' "$label" >&2
    else
      printf '%s [required, ? for help]: ' "$label" >&2
    fi

    old_tty=''
    if [ -t 0 ] && command -v stty >/dev/null 2>&1; then
      old_tty=$(stty -g 2>/dev/null || true)
      stty -echo 2>/dev/null || true
    fi

    IFS= read -r answer || exit 1

    if [ -n "$old_tty" ]; then
      stty "$old_tty" 2>/dev/null || true
    fi
    printf '\n' >&2

    case "$answer" in
      '?')
        bootstrap_info "" >&2
        bootstrap_info "$help_text" >&2
        bootstrap_info "" >&2
        ;;
      '')
        if [ "$keep_existing" = "true" ]; then
          printf '%s' ""
          return 0
        fi
        bootstrap_warn "A value is required."
        ;;
      *)
        printf '%s' "$answer"
        return 0
        ;;
    esac
  done
}

env_exists() {
  env_name="$1"
  bootstrap_env_exists "$env_name"
}

existing_default_env() {
  azd env list | awk 'NR > 1 && $2 == "true" { print $1; exit }'
}

ensure_azure_login() {
  if ! az account show >/dev/null 2>&1; then
    bootstrap_warn "Azure CLI is not signed in yet."
    if prompt_yes_no "Open the Azure CLI sign-in flow now with az login?" "yes" "The bootstrap script can start Azure CLI sign-in for you. This is required so the script can read subscriptions, regions, and optional Entra app registration data."; then
      az login
    else
      bootstrap_error "Azure CLI login is required."
    fi
  fi
}

ensure_azd_login() {
  if ! azd auth login --check-status >/dev/null 2>&1; then
    bootstrap_warn "Azure Developer CLI is not signed in yet."
    if prompt_yes_no "Open the Azure Developer CLI sign-in flow now with azd auth login?" "yes" "The bootstrap script can start Azure Developer CLI sign-in for you. This keeps later preview and deploy steps from stopping for authentication."; then
      azd auth login
    else
      bootstrap_error "Azure Developer CLI login is required."
    fi
  fi
}

ensure_resource_providers() {
  subscription_id="$1"
  missing_namespaces=''
  for namespace in \
    Microsoft.App \
    Microsoft.Cache \
    Microsoft.DBforPostgreSQL \
    Microsoft.KeyVault \
    Microsoft.ManagedIdentity \
    Microsoft.OperationalInsights \
    Microsoft.Storage
  do
    state="$(az provider show --namespace "$namespace" --subscription "$subscription_id" --query registrationState -o tsv 2>/dev/null || printf 'Unknown')"
    if [ "$state" != "Registered" ]; then
      missing_namespaces="${missing_namespaces}${missing_namespaces:+ }$namespace"
    fi
  done

  if [ -z "$missing_namespaces" ]; then
    return 0
  fi

  bootstrap_warn "Some Azure resource providers are not registered: $missing_namespaces"
  if prompt_yes_no "Register the missing providers now?" "yes" "Registering providers up front avoids avoidable azd failures later in provisioning."; then
    for namespace in $missing_namespaces; do
      bootstrap_info "Registering $namespace..."
      az provider register --namespace "$namespace" --subscription "$subscription_id" --wait >/dev/null
    done
  fi
}

choose_environment() {
  if [ -n "$ENVIRONMENT_ARG" ]; then
    AZD_ENV_NAME_SELECTED="$ENVIRONMENT_ARG"
    return 0
  fi

  bootstrap_info ""
  bootstrap_info "Step 1 of 5: Choose an azd environment name."
  bootstrap_info "This name selects an existing azd environment or creates a new one for this repo."
  bootstrap_info ""
  existing_env_output="$(azd env list)"
  bootstrap_info "Existing azd environments:"
  printf '%s\n' "$existing_env_output"
  if ! printf '%s\n' "$existing_env_output" | awk 'NR > 1 && NF > 0 { found=1 } END { exit found ? 0 : 1 }'; then
    bootstrap_info "No azd environments were found. Enter a name below to create your first one."
  fi
  bootstrap_info ""

  suggested_env="$(existing_default_env)"
  [ -n "$suggested_env" ] || suggested_env="dev"
  AZD_ENV_NAME_SELECTED="$(prompt_value "azd environment name" "$suggested_env" "Type the azd environment name to use for this deployment. If the name already exists, the script will update that environment. If it does not exist yet, the script will create it for you." "false")"
}

choose_subscription() {
  current_subscription=''
  current_name=''

  bootstrap_info ""
  bootstrap_info "Step 2 of 5: Choose the Azure subscription for this environment."

  if env_exists "$AZD_ENV_NAME_SELECTED"; then
    current_subscription="$(bootstrap_env_read AZURE_SUBSCRIPTION_ID "$AZD_ENV_NAME_SELECTED")"
  fi
  if [ -z "$current_subscription" ]; then
    current_subscription="$(az account show --query id -o tsv 2>/dev/null || true)"
  fi
  if [ -n "$current_subscription" ]; then
    current_name="$(az account show --subscription "$current_subscription" --query name -o tsv 2>/dev/null || true)"
  fi

  if [ -z "$current_subscription" ]; then
    bootstrap_error "No Azure subscription is currently selected in Azure CLI. Run 'az account list -o table' to see subscriptions, then 'az account set --subscription <subscription-id>' before running this script again."
  fi

  if env_exists "$AZD_ENV_NAME_SELECTED"; then
    bootstrap_info "The existing azd environment '$AZD_ENV_NAME_SELECTED' is currently set to:"
  else
    bootstrap_info "Azure CLI is currently set to:"
  fi
  bootstrap_info "Subscription: ${current_name:-unknown} (${current_subscription})"
  bootstrap_info "Press Enter to use this subscription, or type a different subscription ID."
  AZURE_SUBSCRIPTION_SELECTED="$(prompt_value "Azure subscription ID to use" "$current_subscription" "This script stores the subscription ID in the azd environment so later preview and deploy steps stay non-interactive. Press Enter to keep the subscription already selected in Azure CLI, or paste a different subscription ID if you want to deploy elsewhere." "false")"

  if ! az account show --subscription "$AZURE_SUBSCRIPTION_SELECTED" >/dev/null 2>&1; then
    bootstrap_error "Unable to access subscription $AZURE_SUBSCRIPTION_SELECTED"
  fi
}

choose_location() {
  bootstrap_info ""
  bootstrap_info "Step 3 of 5: Choose the Azure region."

  existing_location=''
  if env_exists "$AZD_ENV_NAME_SELECTED"; then
    existing_location="$(bootstrap_env_read AZURE_LOCATION "$AZD_ENV_NAME_SELECTED")"
  fi
  suggested_location="$existing_location"
  [ -n "$suggested_location" ] || suggested_location="$(bootstrap_default_for_key AZURE_LOCATION)"
  bootstrap_info "Press Enter to use the suggested region, or type a different Azure region name."

  while :; do
    candidate="$(prompt_value "Azure region name" "$suggested_location" "$(bootstrap_help_for_key AZURE_LOCATION)" "false")"
    if bootstrap_subscription_has_location "$AZURE_SUBSCRIPTION_SELECTED" "$candidate"; then
      AZURE_LOCATION_SELECTED="$candidate"
      return 0
    fi
    validation_status=$?
    if [ "$validation_status" -eq 2 ]; then
      bootstrap_error "Unable to validate Azure regions for subscription $AZURE_SUBSCRIPTION_SELECTED. Check Azure CLI access with 'az account show --subscription $AZURE_SUBSCRIPTION_SELECTED' or list regions directly with 'az rest --method get --url https://management.azure.com/subscriptions/$AZURE_SUBSCRIPTION_SELECTED/locations?api-version=2022-12-01'."
    fi
    bootstrap_warn "Location '$candidate' is not available for the selected subscription."
  done
}

choose_deployment_prefix() {
  bootstrap_info ""
  bootstrap_info "Step 4 of 5: Choose a deployment prefix."
  bootstrap_info "This is a short word added to Azure resource names so this deployment is easy to recognize."
  bootstrap_info "Example: if you use the prefix 'dify' and the environment name 'prod', resource names start with values like 'dify-prod-...'."
  bootstrap_info ""

  existing_prefix=''
  if env_exists "$AZD_ENV_NAME_SELECTED"; then
    existing_prefix="$(bootstrap_env_read DEPLOYMENT_PREFIX "$AZD_ENV_NAME_SELECTED")"
  fi

  DEPLOYMENT_PREFIX_SELECTED="$(prompt_value "Deployment prefix" "${existing_prefix:-$(bootstrap_default_for_key DEPLOYMENT_PREFIX)}" "$(bootstrap_help_for_key DEPLOYMENT_PREFIX)" "false")"
  bootstrap_export_value DEPLOYMENT_PREFIX "$DEPLOYMENT_PREFIX_SELECTED"

  bootstrap_preview_truncation_warnings "$AZD_ENV_NAME_SELECTED" "$DEPLOYMENT_PREFIX_SELECTED"
  bootstrap_info ""
  bootstrap_info "Derived name preview:"
  bootstrap_render_name_preview "$AZD_ENV_NAME_SELECTED" "$DEPLOYMENT_PREFIX_SELECTED"
}

ensure_environment_selected() {
  if env_exists "$AZD_ENV_NAME_SELECTED"; then
    bootstrap_info ""
    bootstrap_info "Step 5 of 5: Select the azd environment."
    azd env select "$AZD_ENV_NAME_SELECTED" --no-prompt >/dev/null
    record_summary "AZURE_ENV_NAME" "existing" "$AZD_ENV_NAME_SELECTED"
  else
    bootstrap_info ""
    bootstrap_info "Step 5 of 5: Create the azd environment."
    bootstrap_info "Creating azd environment '$AZD_ENV_NAME_SELECTED'..."
    if ! azd env new "$AZD_ENV_NAME_SELECTED" --subscription "$AZURE_SUBSCRIPTION_SELECTED" --location "$AZURE_LOCATION_SELECTED" --no-prompt; then
      bootstrap_error "Unable to create azd environment '$AZD_ENV_NAME_SELECTED'. Run 'azd env list' to confirm whether it already exists locally, then rerun this script or select the environment manually with 'azd env select $AZD_ENV_NAME_SELECTED'."
    fi
    record_summary "AZURE_ENV_NAME" "chosen" "$AZD_ENV_NAME_SELECTED"
  fi
  bootstrap_export_value AZURE_ENV_NAME "$AZD_ENV_NAME_SELECTED"
}

track_env_value() {
  key="$1"
  value="$2"
  default_value="${3:-}"

  existing_value="$(bootstrap_env_read "$key" "$AZD_ENV_NAME_SELECTED")"
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" "$key" "$value"

  if [ -n "$existing_value" ] && [ "$existing_value" = "$value" ]; then
    record_summary "$key" "existing" "$value"
  elif [ -z "$existing_value" ] && [ -n "$default_value" ] && [ "$default_value" = "$value" ]; then
    record_summary "$key" "defaulted" "$value"
  else
    record_summary "$key" "chosen" "$value"
  fi
}

track_hidden_value() {
  key="$1"
  status="$2"
  record_summary "$key" "$status" "<hidden>"
}

apply_or_prompt_optional_key() {
  key="$1"
  prompt_now="$2"

  current_value="$(bootstrap_env_read "$key" "$AZD_ENV_NAME_SELECTED")"
  default_value="$(bootstrap_default_for_key "$key")"

  if [ "$prompt_now" = "true" ]; then
    chosen_value="$(prompt_value "$key" "${current_value:-$default_value}" "$(bootstrap_help_for_key "$key")" "false")"
    track_env_value "$key" "$chosen_value" "$default_value"
    return 0
  fi

  if [ -n "$current_value" ]; then
    bootstrap_export_value "$key" "$current_value"
    record_summary "$key" "existing" "$current_value"
  else
    bootstrap_env_set "$AZD_ENV_NAME_SELECTED" "$key" "$default_value"
    record_summary "$key" "defaulted" "$default_value"
  fi
}

apply_generated_secrets_with_summary() {
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    current_value="$(bootstrap_env_read "$key" "$AZD_ENV_NAME_SELECTED")"
    if [ -n "$current_value" ]; then
      bootstrap_export_value "$key" "$current_value"
      track_hidden_value "$key" "existing"
    elif bootstrap_env_key_is_explicitly_blank "$key" "$AZD_ENV_NAME_SELECTED"; then
      bootstrap_export_value "$key" ''
      track_hidden_value "$key" "existing-blank"
    else
      bootstrap_env_set "$AZD_ENV_NAME_SELECTED" "$key" "$(bootstrap_generated_secret_value "$key")"
      track_hidden_value "$key" "auto-generated"
    fi
  done <<EOF
$(bootstrap_generated_secret_keys)
EOF
}

create_or_update_entra_registration() {
  existing_app_id="$1"
  tenant_id="$2"
  console_url="$3"
  display_name="$4"

  redirect_uri=''
  if [ -n "$console_url" ]; then
    redirect_uri="${console_url%/}/.auth/login/aad/callback"
  fi

  if [ -n "$existing_app_id" ]; then
    app_id="$existing_app_id"
    az ad app show --id "$app_id" >/dev/null 2>&1 || return 1
  else
    if [ -n "$redirect_uri" ]; then
      app_id="$(az ad app create \
        --display-name "$display_name" \
        --sign-in-audience AzureADMyOrg \
        --enable-id-token-issuance true \
        --web-home-page-url "$console_url" \
        --web-redirect-uris "$redirect_uri" \
        --query appId -o tsv)" || return 1
    else
      app_id="$(az ad app create \
        --display-name "$display_name" \
        --sign-in-audience AzureADMyOrg \
        --enable-id-token-issuance true \
        --query appId -o tsv)" || return 1
    fi
  fi

  az ad app update --id "$app_id" --enable-id-token-issuance true >/dev/null || return 1

  if [ -n "$redirect_uri" ]; then
    ensure_entra_web_redirect_uri "$app_id" "$redirect_uri" || return 1
    az ad app update --id "$app_id" --web-home-page-url "$console_url" >/dev/null || return 1
  fi

  az ad sp create --id "$app_id" >/dev/null 2>&1 || true
  client_secret="$(az ad app credential reset --id "$app_id" --append --display-name "${AZD_ENV_NAME_SELECTED}-console-auth" --query password -o tsv)" || return 1

  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENTRA_CLIENT_ID "$app_id"
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENTRA_CLIENT_SECRET "$client_secret"
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENTRA_TENANT_ID "$tenant_id"
  return 0
}

update_entra_redirect() {
  app_id="$1"
  console_url="$2"

  redirect_uri="${console_url%/}/.auth/login/aad/callback"
  az ad app update --id "$app_id" --enable-id-token-issuance true >/dev/null || return 1
  ensure_entra_web_redirect_uri "$app_id" "$redirect_uri" || return 1
  az ad app update --id "$app_id" --web-home-page-url "$console_url" >/dev/null || return 1
}

ensure_entra_web_redirect_uri() {
  app_id="$1"
  redirect_uri="$2"

  [ -n "$redirect_uri" ] || return 0

  if az ad app show --id "$app_id" --query "contains(web.redirectUris, '$redirect_uri')" -o tsv 2>/dev/null | grep -qi '^true$'; then
    return 0
  fi

  existing_redirect_uris="$(az ad app show --id "$app_id" --query "web.redirectUris[]" -o tsv 2>/dev/null)" || return 1
  if [ -n "$existing_redirect_uris" ]; then
    # Redirect URIs are whitespace-free, so passing the existing tsv output back to Azure CLI preserves the full set.
    az ad app update --id "$app_id" --web-redirect-uris $existing_redirect_uris "$redirect_uri" >/dev/null || return 1
  else
    az ad app update --id "$app_id" --web-redirect-uris "$redirect_uri" >/dev/null || return 1
  fi
}

print_manual_entra_steps() {
  console_url="$1"
  app_id_hint="$2"

  bootstrap_info ""
  bootstrap_info "Manual Entra steps:"
  bootstrap_info "1. Use or create a single-tenant app registration for the console gateway."
  bootstrap_info "2. Enable ID token issuance:"
  if [ -n "$app_id_hint" ]; then
    bootstrap_info "   az ad app update --id $app_id_hint --enable-id-token-issuance true"
  else
    bootstrap_info "   az ad app update --id <app-registration-client-id> --enable-id-token-issuance true"
  fi
  if [ -n "$console_url" ]; then
    bootstrap_info "3. Add the console redirect URI:"
    if [ -n "$app_id_hint" ]; then
      bootstrap_info "   az ad app update --id $app_id_hint --web-redirect-uris ${console_url%/}/.auth/login/aad/callback"
    else
      bootstrap_info "   az ad app update --id <app-registration-client-id> --web-redirect-uris ${console_url%/}/.auth/login/aad/callback"
    fi
    bootstrap_info "   Include any existing web redirect URIs you still need in the same command, because Azure CLI replaces the full web redirect URI list."
  else
    bootstrap_info "3. After the first deployment, add this redirect URI:"
    bootstrap_info "   <CONSOLE_URL>/.auth/login/aad/callback"
  fi
  bootstrap_info "4. Create or copy a client secret value and keep the tenant ID, client ID, and secret ready for this azd environment."
  bootstrap_info ""
}

configure_console_auth() {
  current_enable="$(bootstrap_normalize_bool "$(bootstrap_env_read ENABLE_CONSOLE_AUTH "$AZD_ENV_NAME_SELECTED")")"
  pending_auth="$(bootstrap_normalize_bool "$(bootstrap_env_read BOOTSTRAP_PENDING_CONSOLE_AUTH "$AZD_ENV_NAME_SELECTED")")"
  current_console_url="$(bootstrap_env_read CONSOLE_URL "$AZD_ENV_NAME_SELECTED")"

  bootstrap_info ""
  bootstrap_info "Console sign-in notes:"
  bootstrap_info "- Microsoft Entra sign-in is optional."
  bootstrap_info "- This repo currently uses a single-tenant Container Apps auth setup."
  bootstrap_info "- The final redirect URI must be <CONSOLE_URL>/.auth/login/aad/callback."
  bootstrap_info "- Brand-new environments usually need one deployment before CONSOLE_URL is known."
  bootstrap_info ""

  default_enable="no"
  if [ "$current_enable" = "true" ] || [ "$pending_auth" = "true" ]; then
    default_enable="yes"
  fi

  if ! prompt_yes_no "Enable console sign-in with Microsoft Entra ID?" "$default_enable" "Choose yes to configure or resume the console SSO branch. Choose no to keep the console publicly reachable and skip all Entra app registration work."; then
    track_env_value ENABLE_CONSOLE_AUTH false false
    bootstrap_env_set "$AZD_ENV_NAME_SELECTED" BOOTSTRAP_PENDING_CONSOLE_AUTH false
    record_summary "BOOTSTRAP_PENDING_CONSOLE_AUTH" "chosen" "false"
    return 0
  fi

  current_tenant_id="$(bootstrap_env_read ENTRA_TENANT_ID "$AZD_ENV_NAME_SELECTED")"
  [ -n "$current_tenant_id" ] || current_tenant_id="$(bootstrap_guess_tenant_id "$AZD_ENV_NAME_SELECTED")"

  if prompt_yes_no "Let this script create or update the Entra app registration when permissions allow?" "yes" "The script can create a single-tenant app registration, enable ID token issuance, add the redirect URI when known, and generate a client secret. If that fails, it falls back to manual instructions."; then
    existing_client_id="$(bootstrap_env_read ENTRA_CLIENT_ID "$AZD_ENV_NAME_SELECTED")"
    client_id_hint="$(prompt_value "Existing Entra app registration client ID" "$existing_client_id" "Leave this blank to create a new single-tenant app registration. Provide a client ID when you want the script to update an existing registration instead." "true")"
    display_name_default="$(bootstrap_trim_to 120 "${AZD_ENV_NAME_SELECTED}-console-auth")"
    display_name=''
    if [ -z "$client_id_hint" ]; then
      display_name="$(prompt_value "New Entra app display name" "$display_name_default" "Display name for the auto-created single-tenant Entra app registration." "false")"
    fi

    tenant_id_value="$(prompt_value "Entra tenant ID" "$current_tenant_id" "$(bootstrap_help_for_key ENTRA_TENANT_ID)" "false")"
    if create_or_update_entra_registration "$client_id_hint" "$tenant_id_value" "$current_console_url" "$display_name"; then
      record_summary "ENTRA_TENANT_ID" "chosen" "$tenant_id_value"
      record_summary "ENTRA_CLIENT_ID" "chosen" "$(bootstrap_env_read ENTRA_CLIENT_ID "$AZD_ENV_NAME_SELECTED")"
      track_hidden_value "ENTRA_CLIENT_SECRET" "chosen"
    else
      bootstrap_warn "Automatic Entra app registration setup failed. Falling back to manual guidance."
      print_manual_entra_steps "$current_console_url" "$client_id_hint"
      prompt_manual_console_auth "$current_tenant_id"
    fi
  else
    prompt_manual_console_auth "$current_tenant_id"
  fi

  if [ -n "$current_console_url" ]; then
    if ! prompt_yes_no "Have the redirect URI and ID-token settings been completed for ${current_console_url%/}/.auth/login/aad/callback?" "yes" "Answer yes only after the Entra app registration is fully configured for the current console URL."; then
      bootstrap_warn "Console auth will remain pending until the Entra app registration is updated."
      bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENABLE_CONSOLE_AUTH false
      bootstrap_env_set "$AZD_ENV_NAME_SELECTED" BOOTSTRAP_PENDING_CONSOLE_AUTH true
      record_summary "ENABLE_CONSOLE_AUTH" "chosen" "false"
      record_summary "BOOTSTRAP_PENDING_CONSOLE_AUTH" "chosen" "true"
      return 0
    fi

    track_env_value ENABLE_CONSOLE_AUTH true false
    bootstrap_env_set "$AZD_ENV_NAME_SELECTED" BOOTSTRAP_PENDING_CONSOLE_AUTH false
    record_summary "BOOTSTRAP_PENDING_CONSOLE_AUTH" "chosen" "false"
  else
    bootstrap_info "CONSOLE_URL is not known yet, so the first deployment will keep console auth disabled and mark the environment for a second pass."
    bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENABLE_CONSOLE_AUTH false
    bootstrap_env_set "$AZD_ENV_NAME_SELECTED" BOOTSTRAP_PENDING_CONSOLE_AUTH true
    record_summary "ENABLE_CONSOLE_AUTH" "chosen" "false"
    record_summary "BOOTSTRAP_PENDING_CONSOLE_AUTH" "chosen" "true"
  fi
}

prompt_manual_console_auth() {
  current_tenant_id="$1"
  existing_client_id="$(bootstrap_env_read ENTRA_CLIENT_ID "$AZD_ENV_NAME_SELECTED")"
  existing_secret="$(bootstrap_env_read ENTRA_CLIENT_SECRET "$AZD_ENV_NAME_SELECTED")"

  print_manual_entra_steps "$(bootstrap_env_read CONSOLE_URL "$AZD_ENV_NAME_SELECTED")" "$existing_client_id"

  tenant_id_value="$(prompt_value "Entra tenant ID" "$current_tenant_id" "$(bootstrap_help_for_key ENTRA_TENANT_ID)" "false")"
  client_id_value="$(prompt_value "Entra app registration client ID" "$existing_client_id" "$(bootstrap_help_for_key ENTRA_CLIENT_ID)" "false")"
  if [ -n "$existing_secret" ]; then
    client_secret_value="$(prompt_secret_value "Entra app registration client secret" "true" "$(bootstrap_help_for_key ENTRA_CLIENT_SECRET)")"
    if [ -n "$client_secret_value" ]; then
      record_summary "ENTRA_CLIENT_SECRET" "chosen" "<hidden>"
    else
      client_secret_value="$existing_secret"
      record_summary "ENTRA_CLIENT_SECRET" "existing" "<hidden>"
    fi
  else
    client_secret_value="$(prompt_secret_value "Entra app registration client secret" "false" "$(bootstrap_help_for_key ENTRA_CLIENT_SECRET)")"
    record_summary "ENTRA_CLIENT_SECRET" "chosen" "<hidden>"
  fi

  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENTRA_TENANT_ID "$tenant_id_value"
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENTRA_CLIENT_ID "$client_id_value"
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENTRA_CLIENT_SECRET "$client_secret_value"
  record_summary "ENTRA_TENANT_ID" "chosen" "$tenant_id_value"
  record_summary "ENTRA_CLIENT_ID" "chosen" "$client_id_value"
}

resume_pending_console_auth() {
  pending_auth="$(bootstrap_normalize_bool "$(bootstrap_env_read BOOTSTRAP_PENDING_CONSOLE_AUTH "$AZD_ENV_NAME_SELECTED")")"
  [ "$pending_auth" = "true" ] || return 0

  azd env refresh -e "$AZD_ENV_NAME_SELECTED" >/dev/null 2>&1 || true
  console_url="$(bootstrap_env_read CONSOLE_URL "$AZD_ENV_NAME_SELECTED")"
  if [ -z "$console_url" ]; then
    bootstrap_warn "Console auth is pending, but CONSOLE_URL is still unavailable."
    return 1
  fi

  bootstrap_info ""
  bootstrap_info "Console auth is pending and CONSOLE_URL is now available: $console_url"
  client_id="$(bootstrap_env_read ENTRA_CLIENT_ID "$AZD_ENV_NAME_SELECTED")"
  client_secret="$(bootstrap_env_read ENTRA_CLIENT_SECRET "$AZD_ENV_NAME_SELECTED")"
  tenant_id="$(bootstrap_env_read ENTRA_TENANT_ID "$AZD_ENV_NAME_SELECTED")"

  if [ -z "$client_id" ] || [ -z "$client_secret" ] || [ -z "$tenant_id" ]; then
    bootstrap_warn "ENTRA_CLIENT_ID, ENTRA_CLIENT_SECRET, or ENTRA_TENANT_ID is missing, so the script cannot finish the auth enablement step."
    print_manual_entra_steps "$console_url" "$client_id"
    return 1
  fi

  if prompt_yes_no "Update the Entra app registration redirect URI automatically now?" "yes" "This step ensures the app registration has ID-token issuance enabled and includes ${console_url%/}/.auth/login/aad/callback as a web redirect URI."; then
    if ! update_entra_redirect "$client_id" "$console_url"; then
      bootstrap_warn "Automatic redirect update failed."
      print_manual_entra_steps "$console_url" "$client_id"
      if ! prompt_yes_no "Have you completed the redirect update manually?" "no" "Choose yes only after the Entra app registration has the correct redirect URI and ID-token issuance enabled."; then
        return 1
      fi
    fi
  else
    print_manual_entra_steps "$console_url" "$client_id"
    if ! prompt_yes_no "Have you completed the redirect update manually?" "no" "Choose yes only after the Entra app registration has the correct redirect URI and ID-token issuance enabled."; then
      return 1
    fi
  fi

  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENABLE_CONSOLE_AUTH true
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" BOOTSTRAP_PENDING_CONSOLE_AUTH false
  bootstrap_validate_console_auth_inputs "$AZD_ENV_NAME_SELECTED"
  bootstrap_info "Console auth configuration is ready. A second azd deployment pass will apply it."
  return 0
}

run_preview() {
  bootstrap_info ""
  bootstrap_info "Running azd provision --preview..."
  azd provision -e "$AZD_ENV_NAME_SELECTED" --preview
}

run_up() {
  bootstrap_info ""
  bootstrap_info "Running azd up..."
  azd up -e "$AZD_ENV_NAME_SELECTED"
}

apply_core_values() {
  existing_subscription="$(bootstrap_env_read AZURE_SUBSCRIPTION_ID "$AZD_ENV_NAME_SELECTED")"
  if [ -n "$existing_subscription" ] && [ "$existing_subscription" = "$AZURE_SUBSCRIPTION_SELECTED" ]; then
    record_summary "AZURE_SUBSCRIPTION_ID" "existing" "$AZURE_SUBSCRIPTION_SELECTED"
  else
    record_summary "AZURE_SUBSCRIPTION_ID" "chosen" "$AZURE_SUBSCRIPTION_SELECTED"
  fi
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" AZURE_SUBSCRIPTION_ID "$AZURE_SUBSCRIPTION_SELECTED"

  existing_location="$(bootstrap_env_read AZURE_LOCATION "$AZD_ENV_NAME_SELECTED")"
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" AZURE_LOCATION "$AZURE_LOCATION_SELECTED"
  if [ -n "$existing_location" ] && [ "$existing_location" = "$AZURE_LOCATION_SELECTED" ]; then
    record_summary "AZURE_LOCATION" "existing" "$AZURE_LOCATION_SELECTED"
  elif [ -z "$existing_location" ] && [ "$AZURE_LOCATION_SELECTED" = "$(bootstrap_default_for_key AZURE_LOCATION)" ]; then
    record_summary "AZURE_LOCATION" "defaulted" "$AZURE_LOCATION_SELECTED"
  else
    record_summary "AZURE_LOCATION" "chosen" "$AZURE_LOCATION_SELECTED"
  fi

  prefix_current="$(bootstrap_env_read DEPLOYMENT_PREFIX "$AZD_ENV_NAME_SELECTED")"
  prefix_value="${DEPLOYMENT_PREFIX_SELECTED:-${prefix_current:-$(bootstrap_default_for_key DEPLOYMENT_PREFIX)}}"
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" DEPLOYMENT_PREFIX "$prefix_value"
  if [ -n "$prefix_current" ] && [ "$prefix_current" = "$prefix_value" ]; then
    record_summary "DEPLOYMENT_PREFIX" "existing" "$prefix_value"
  elif [ -z "$prefix_current" ] && [ "$prefix_value" = "$(bootstrap_default_for_key DEPLOYMENT_PREFIX)" ]; then
    record_summary "DEPLOYMENT_PREFIX" "defaulted" "$prefix_value"
  else
    record_summary "DEPLOYMENT_PREFIX" "chosen" "$prefix_value"
  fi
}

bootstrap_require_cmd azd
bootstrap_require_cmd az
bootstrap_require_cmd openssl

bootstrap_info "This guided setup prepares an azd environment for deploying Dify to Azure Container Apps."
bootstrap_info "It can also run 'azd provision --preview' and 'azd up' after the environment values are saved."
bootstrap_info "If Azure CLI or Azure Developer CLI is not signed in yet, this script can start 'az login' and 'azd auth login' for you."
bootstrap_info "The file .azure/<env>/.env is gitignored, but it still stores local plaintext values before Azure resources exist. Handle that file as sensitive."

ensure_azure_login
ensure_azd_login
choose_environment
choose_subscription
choose_location
choose_deployment_prefix
ensure_resource_providers "$AZURE_SUBSCRIPTION_SELECTED"
ensure_environment_selected
apply_core_values

if prompt_yes_no "Do you want to customize advanced database, Redis, or image settings now?" "no" "Choose yes only if you want to override PostgreSQL sizing, Redis SKU, or the default container image tags. Choose no to keep the current environment values or the repo defaults."; then
  prompt_advanced="true"
else
  prompt_advanced="false"
fi

for key in \
  POSTGRES_ADMIN_USERNAME \
  POSTGRES_SKU_NAME \
  POSTGRES_SKU_TIER \
  POSTGRES_STORAGE_GB \
  REDIS_SKU_NAME \
  DIFY_API_IMAGE \
  DIFY_WEB_IMAGE \
  DIFY_SANDBOX_IMAGE \
  DIFY_PLUGIN_DAEMON_IMAGE \
  GATEWAY_IMAGE \
  SSRF_PROXY_IMAGE
do
  apply_or_prompt_optional_key "$key" "$prompt_advanced"
done

tenant_guess="$(bootstrap_guess_tenant_id "$AZD_ENV_NAME_SELECTED")"
tenant_current="$(bootstrap_env_read ENTRA_TENANT_ID "$AZD_ENV_NAME_SELECTED")"
if [ -z "$tenant_current" ] && [ -n "$tenant_guess" ]; then
  bootstrap_env_set "$AZD_ENV_NAME_SELECTED" ENTRA_TENANT_ID "$tenant_guess"
fi

configure_console_auth
apply_generated_secrets_with_summary
bootstrap_validate_console_auth_inputs "$AZD_ENV_NAME_SELECTED"
render_summary

bootstrap_info ""
bootstrap_info "What would you like the script to do next?"
bootstrap_info "1. preview  - show the Azure infrastructure changes without deploying them"
bootstrap_info "2. up       - deploy the environment now with azd up"
bootstrap_info "3. write    - only save the environment file and stop"
action="$(prompt_value "Next action (preview/up/write)" "up" "Choose 'preview' to inspect the infrastructure diff first, 'up' to deploy now, or 'write' to stop after saving the azd environment values." "false")"

case "$(bootstrap_lower "$action")" in
  preview)
    run_preview
    if prompt_yes_no "Run azd up after the preview?" "yes" "Choose yes to continue with the actual deployment after reviewing the preview output."; then
      run_up
    fi
    ;;
  up)
    run_up
    ;;
  write)
    bootstrap_info "Configuration written to .azure/$AZD_ENV_NAME_SELECTED/.env"
    exit 0
    ;;
  *)
    bootstrap_error "Unsupported action: $action"
    ;;
esac

if resume_pending_console_auth; then
  if prompt_yes_no "Run azd provision --preview before the console-auth enablement pass?" "yes" "This optional second preview shows the change from ENABLE_CONSOLE_AUTH=false to ENABLE_CONSOLE_AUTH=true once the redirect URI is in place."; then
    run_preview
  fi
  if prompt_yes_no "Run azd up again to apply console auth now?" "yes" "This second deployment pass applies the finalized Entra auth settings to the console gateway."; then
    run_up
  fi
fi

bootstrap_info ""
bootstrap_info "Deployment outputs:"
for key in CONSOLE_URL APP_URL KEY_VAULT_NAME POSTGRES_SERVER_NAME REDIS_HOSTNAME; do
  value="$(bootstrap_env_read "$key" "$AZD_ENV_NAME_SELECTED")"
  if [ -n "$value" ]; then
    printf '  %s=%s\n' "$key" "$value"
  fi
done

bootstrap_info ""
bootstrap_info "Remaining manual Dify steps after a successful deployment:"
bootstrap_info "1. Open CONSOLE_URL."
bootstrap_info "2. Complete the Dify install flow."
bootstrap_info "3. Add model provider credentials in the Dify UI."
bootstrap_info "4. Validate uploads, background jobs, and dataset indexing."
