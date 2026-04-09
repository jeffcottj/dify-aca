#!/usr/bin/env zsh
set -euo pipefail

if ! command -v dnx >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Bicep MCP is configured for this project, but it requires .NET 10 SDK with `dnx`.

Install .NET 10 SDK so this project-local MCP can run:
  https://learn.microsoft.com/en-us/dotnet/core/install/

Then verify:
  dotnet --info
  dnx --help

After that, restart Codex in this repo.
EOF
  exit 1
fi

exec dnx -y Azure.Bicep.McpServer
