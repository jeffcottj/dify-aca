#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/bootstrap-common.sh
. "$SCRIPT_DIR/lib/bootstrap-common.sh"

bootstrap_require_cmd azd
bootstrap_require_cmd az
bootstrap_require_cmd openssl

if [ -z "${AZURE_ENV_NAME:-}" ]; then
  bootstrap_error "AZURE_ENV_NAME is required in the preprovision hook."
fi

bootstrap_apply_default_values "$AZURE_ENV_NAME"
bootstrap_apply_generated_secrets "$AZURE_ENV_NAME"
bootstrap_validate_console_auth_inputs "$AZURE_ENV_NAME"
