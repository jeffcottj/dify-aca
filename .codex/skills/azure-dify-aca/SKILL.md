---
name: azure-dify-aca
description: Use this skill when designing, implementing, or validating Dify deployment automation in this repository for Azure Container Apps, Azure Database for PostgreSQL, Azure Cache for Redis, and Azure Blob Storage, with Bicep as the preferred IaC path.
---

# Azure Dify on ACA

Use this skill when the task involves Azure infrastructure design, Bicep authoring, Azure CLI workflows, or Dify-to-Azure deployment mapping in this repository.

## Preconditions

- Prefer the project-local `microsoft-learn` MCP server for Azure service docs, quotas, limits, CLI syntax, and architecture guidance.
- Prefer the project-local `azure` MCP server for live Azure discovery or validation once Azure authentication is available.
- Prefer the project-local `bicep` MCP server for Bicep syntax, diagnostics, formatting, ARM decompilation, AVM discovery, and resource-type schema when local `.NET 10` and `dnx` are available.
- If the `bicep` MCP server is unavailable, fall back to Azure MCP Bicep-oriented tools such as `bicepschema get` and the Azure IaC best-practices tooling.
- Never assume Dify's Docker Compose defaults map directly onto Azure Container Apps. Verify every dependency and environment variable against current upstream docs.

## Working Rules

1. For factual Azure questions, start with Microsoft Learn before falling back to general web search.
2. For Bicep questions, verify resource schema, API versions, AVM options, and diagnostics through Bicep MCP or Azure MCP before writing templates.
3. Keep infrastructure changes reviewable:
   - separate platform primitives from Dify app configuration
   - keep secrets out of source control
   - prefer managed identity and RBAC over connection strings where Azure supports it
   - prefer Bicep and Azure Verified Modules over Terraform unless there is a concrete reason not to
4. Treat background workers, Redis usage, blob/file storage, and ingress/networking as first-class deployment concerns, not afterthoughts.

## Deployment Focus Areas

- Azure Container Apps environment, revisions, ingress, jobs, and scaling
- Azure Database for PostgreSQL flexible server configuration and connectivity
- Azure Cache for Redis connectivity, TLS, and Dify task queue expectations
- Azure Blob Storage container layout and Dify file storage settings
- Identity, secret distribution, and DNS/TLS

## Reference Workflow

1. Confirm the upstream Dify components and required environment variables.
2. Map each component to Azure services and note any gaps or incompatibilities.
3. Verify Azure implementation details in Microsoft Learn.
4. Verify Bicep resource shape, diagnostics, and best practices in Bicep MCP or Azure MCP.
5. Only then write or revise infrastructure code in this repo.
