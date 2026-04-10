#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/bootstrap-common.sh
. "$SCRIPT_DIR/lib/bootstrap-common.sh"

assert_eq() {
  expected="$1"
  actual="$2"
  message="$3"

  if [ "$expected" != "$actual" ]; then
    printf 'Assertion failed: %s\nExpected: %s\nActual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  haystack="$1"
  needle="$2"
  message="$3"

  if ! printf '%s' "$haystack" | grep -F "$needle" >/dev/null 2>&1; then
    printf 'Assertion failed: %s\nMissing: %s\n' "$message" "$needle" >&2
    exit 1
  fi
}

assert_eq "team-dev" "$(bootstrap_normalize_token 'Team.Dev')" "normalize_token should lowercase and replace separators"
assert_eq "abcdef" "$(bootstrap_trim_to 6 'abcdefghij')" "trim_to should enforce the requested limit"
assert_eq "dify" "$(bootstrap_default_for_key DEPLOYMENT_PREFIX)" "default deployment prefix should stay stable"
assert_eq "false" "$(bootstrap_normalize_bool 'No')" "normalize_bool should map falsey input to false"

preview="$(bootstrap_render_name_preview 'VeryLongEnvironmentName' 'DifyTeam')"
assert_contains "$preview" "Console gateway app:" "name preview should include container app output"
assert_contains "$preview" "Storage account:" "name preview should include storage output"

secret_value="$(bootstrap_generated_secret_value DIFY_SECRET_KEY)"
assert_contains "$secret_value" "sk-" "generated DIFY secret should preserve the sk- prefix"

printf 'bootstrap-common smoke tests passed\n'
