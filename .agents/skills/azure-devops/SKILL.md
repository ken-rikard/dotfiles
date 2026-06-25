---
name: azure-devops
description: "Comprehensive guidance for Azure DevOps pipelines, work items, variable groups, NuGet packages, and CI/CD management. Covers Docker Swarm deployment pipelines, .NET build/test/publish pipelines, work item management with custom fields, variable group creation, NuGet package generation, template reuse, and Azure DevOps CLI commands. WHEN: Azure DevOps, Azure Pipelines, CI/CD, pipeline YAML, DevOps CLI, work item management, variable groups, NuGet feed, ADO organization, Pipeline templates, Docker Swarm pipeline, DevOps work item, az boards, az pipelines, DevOps build, DevOps release, DevOps NuGet."
license: MIT
metadata:
  author: PlanCRM
  version: "1.0.0"
---

# Azure DevOps Skill

This skill provides **comprehensive guidance** for working with Azure DevOps in the PlanCRM/PlanBackOffice ecosystem. It covers pipeline creation, work item management, variable groups, NuGet packages, and day-to-day operations.

## When to Use This Skill

- User asks about **Azure DevOps** organization, projects, or configuration
- User needs to **create or modify pipelines** (Docker Swarm, standard .NET, NuGet)
- User asks about **work items** (create, update, query, attachments)
- User needs **variable group** management (create, populate, update)
- User needs to work with **NSwag client generation** / NuGet feeds
- User asks about **pipeline templates** or reusable steps
- User needs **Azure CLI commands** for Azure DevOps
- User encounters **pipeline errors** or build failures
- User asks about **branch policies**, triggers, or environment promotion

## Prerequisites

- Access to Azure DevOps organization: `https://dev.azure.com/PlanInternational-PlanCRM`
- Project: `PlanBackOffice`
- Azure CLI with `devops` extension: `az extension add --name azure-devops`
- Default Azure DevOps organization configured: `az devops configure --defaults organization=https://dev.azure.com/PlanInternational-PlanCRM project=PlanBackOffice`
- For pipeline operations: contributor access to the project
- For Docker Swarm pipelines: access to self-hosted agent pool `NNO-pipe` / agent `docker01`

## Quick Reference

```bash
# Common aliases
ORG="https://dev.azure.com/PlanInternational-PlanCRM"
PROJECT="PlanBackOffice"

# Set defaults once
az devops configure --defaults organization=$ORG project=$PROJECT

# Verify configuration
az devops configure --list
```

## Table of Contents

1. [Organization & Project Overview](#organization--project-overview)
2. [Pipeline Architecture](#pipeline-architecture)
3. [Docker Swarm CI/CD Pipeline](#docker-swarm-cicd-pipeline)
4. [Standard .NET Build Pipelines](#standard-net-build-pipelines)
5. [NuGet Package Pipeline](#nuget-package-pipeline)
6. [Pipeline Templates](#pipeline-templates)
7. [Variable Groups](#variable-groups)
8. [Work Item Management](#work-item-management)
9. [Azure CLI Operations](#azure-cli-operations)
10. [Troubleshooting & Common Issues](#troubleshooting--common-issues)

---

## Organization & Project Overview

| Property | Value |
|----------|-------|
| Organization URL | `https://dev.azure.com/PlanInternational-PlanCRM` |
| Project | `PlanBackOffice` |
| Container Registry | `plandockerapps.azurecr.io` (Azure Container Registry) |
| Build Agent Pool | `ubuntu-latest` (Microsoft-hosted) |
| Deploy Agent Pool | `NNO-pipe` / `docker01` (self-hosted, Docker Swarm manager) |
| NuGet Feed | `CDM.NET` (feed ID: `0cf3d305-b067-4202-995b-1a634ff8d187`) |
| GitHub Repo | Project repository at `/home/kenr/Repos/Plan/PlanBackOffice` |

### Service Connections

The Azure Container Registry uses a service connection authenticated via variable group `ACR-credentials` (shared across all pipelines).

---

## Pipeline Architecture

### Pipeline Directory Layout

All pipeline YAML files live under `Pipelines/` in the repo root:

```
Pipelines/
├── azure-pipelines.yml                       # Root orchestrator
├── azure-pipelines-Frontend.yml              # Legacy frontend build
├── azure-pipelines-docker-blazor-Frontend.yml # Frontend Docker Swarm deploy
├── azure-pipelines-Worker.yml                # Worker build
├── azure-pipelines-childdata_proxy.yml       # Child data proxy
├── azure-pipelines.net6.yml                  # Legacy .NET 6 build
├── azurepipelines-coverage.yml               # Code coverage config
├── Services/
│   ├── azure-pipelines-docker-childdata-proxy.yml
│   ├── plancrm.helper-pipeline.yml
│   └── plancrm.helper-pipeline-build.yml
├── SyncService/
│   ├── azure-pipelines-docker-syncservice-api.yml
│   ├── asset.api-pipeline.yml
│   ├── letter.api-pipeline.yml
│   └── syncservice-nuget-pipeline.yml
└── Templates/
    ├── api-publish-steps.yml                 # Publish .NET API steps
    ├── create-api-client-steps.yml           # NSwag client generation
    └── nuget-push-steps.yml                  # NuGet push steps
```

### Pipeline Types

The project uses three pipeline patterns:

1. **Docker Swarm pipelines** — Build Docker images, deploy to Docker Swarm (dev → test → prod)
2. **Standard build pipelines** — Restore, build, test, and publish .NET projects (no Docker)
3. **NuGet package pipelines** — Generate NSwag API clients and publish to Azure Artifacts

---

## Docker Swarm CI/CD Pipeline

The canonical template is `Pipelines/azure-pipelines-docker-blazor-Frontend.yml`.

### Branch → Environment Mapping

| Branch | Environments |
|--------|-------------|
| `develop` | Build → Dev |
| `master` | Build → Dev → Test |
| `release` | Build → Dev → Test → Prod |

### Architecture

```
Build (Microsoft-hosted ubuntu-latest)
  └─ DeployDev (self-hosted NNO-pipe/docker01, automatic)
      └─ DeployTest (self-hosted, manual approval gate, main/release only)
          └─ DeployProd (self-hosted, manual approval gate, release only)
```

### Template Placeholders

When creating a new Docker Swarm pipeline, adapt these variables:

| Placeholder | Description | Example |
|-------------|-------------|---------|
| `{{TRIGGER_PATH}}` | Folder path that triggers builds | `Frontend/*` |
| `{{PROJECT_NAME}}` | Kebab-case service name | `cdm-web` |
| `{{PROJECT_DISPLAY_NAME}}` | Human-readable name | `cdm-web` |
| `{{PROJECT_PATH}}` | Path to `.csproj` | `Frontend/Web/Web.csproj` |
| `{{DOCKERFILE_PATH}}` | Path to Dockerfile | `Frontend/Dockerfile` |
| `{{IMAGE_SUFFIX}}` | ACR image name suffix | `blazor-frontend` |
| `{{DEV_PORT}}` | Host port for dev | `8098` |
| `{{TEST_PORT}}` | Host port for test | `8099` |
| `{{PROD_PORT}}` | Host port for prod | `8100` |
| `{{CONTAINER_PORT}}` | Internal container port | `8098` |
| `{{NETWORK_PREFIX}}` | Overlay network prefix | `cdm` |
| `{{VARIABLE_GROUP_PREFIX}}` | Variable group naming prefix | `CDM-blazor-frontend` |

### Workflow for Creating a New Docker Swarm Pipeline

1. **Gather project info** — name, ports, trigger paths
2. **Scan `appsettings.json`** — identify environment variables using `__` (double underscore) for nested config
3. **Classify each setting** — secret vs non-secret, same vs per-environment
4. **Generate pipeline YAML** from the template with correct variables
5. **Create 3 variable groups** (`-dev`, `-test`, `-prod` via Azure CLI)
6. **Populate variable groups** with correct values per environment
7. **Add health check endpoint** to `Program.cs` if missing (`app.MapHealthChecks("/health")`)
8. **Add `curl` to `Dockerfile`** if missing
9. **Verify** variable groups match pipeline env vars
10. **Ensure overlay networks** exist for new network prefixes

### Port Allocation Convention

Services use 3 sequential ports (dev, test, prod):
```bash
# Check existing ports on the Swarm manager
docker service ls --format "table {{.Name}}\t{{.Ports}}"
```

### Environment Variable Naming

ASP.NET Core uses `__` (double underscore) for nested config in Docker env vars:
```
appsettings.json:  "ConnectionStrings": { "Bisnode": "..." }
Docker env var:    ConnectionStrings__Bisnode=...
```

**CRITICAL**: Never use dot notation (`AzureAd.ClientSecret`) — it does not work for ASP.NET Core config binding via Docker env vars.

### Standard Docker Environment Variables

Every service gets these:
- `ASPNETCORE__ENVIRONMENT` — `Development` / `Test` / `Production`
- `ASPNETCORE__FORWARDEDHEADERS_ENABLED` — `true`
- `ASPNETCORE__URLS` — `http://+:<CONTAINER_PORT>`

### Docker Swarm Service Commands

**`service update`** (existing service): Use `--env-add` for env vars, `--label-add` for labels
**`service create`** (new service): Use `--env` (NOT `--env-add`), `--label` (NOT `--label-add`)

Always include health checks:
```yaml
--health-cmd "curl -f http://localhost:$(CONTAINER_PORT)/health || exit 1" \
--health-interval 30s --health-retries 3 --health-start-period 30s
```

### Image Cleanup

Add image pruning after Dev and Prod deploys:
```yaml
- script: |
    $(RUNTIME_CMD) image prune -af --filter "until=168h" || true
  displayName: "Cleanup Old Images"
  condition: always()
```

---

## Standard .NET Build Pipelines

Used for projects that publish build artifacts rather than Docker images (e.g., helper APIs, workers).

### Pattern

```yaml
trigger:
  branches:
    include:
      - master
      - develop
  paths:
    include:
      - Backend/Services/PlanCrm.Helper/*

pool:
  vmImage: ubuntu-latest

variables:
  buildConfiguration: "Release"
  projectFolder: "Backend/Services/PlanCrm.Helper/PlanCrm.Helper.Api"

stages:
  - stage: 'Build'
    jobs:
    - job: Build
      steps:
        - task: UseDotNet@2
          inputs:
            packageType: "sdk"
            version: "8.x"

        - task: DotNetCoreCLI@2
          displayName: "Restore"
          inputs:
            command: "restore"
            projects: "**/$(projectFolder)/*.csproj"
            vstsFeed: "0cf3d305-b067-4202-995b-1a634ff8d187/aa78e24d-62e0-41c5-a2dc-1524b161ac92"

        - task: DotNetCoreCLI@2
          displayName: "Build"
          inputs:
            command: "build"
            projects: "**/$(projectFolder)/*.csproj"

    - job: Publish
      condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/master'))
      steps:
        - task: DotNetCoreCLI@2
          inputs:
            command: "publish"
            publishWebProjects: false
            projects: "**/$(projectFolder)/*.csproj"
            arguments: "--configuration $(BuildConfiguration) --output $(Build.ArtifactStagingDirectory)"
            zipAfterPublish: false

        - task: PublishBuildArtifacts@1
          inputs:
            PathtoPublish: "$(Build.ArtifactStagingDirectory)"
            ArtifactName: "drop"
            publishLocation: "Container"
```

### .NET SDK Version

| Project | SDK Version |
|---------|-------------|
| Docker Swarm projects | `10.0.x` |
| PlanCrm.Helper | `8.x` |
| Legacy pipelines | `6.x` (net6.0) |

### NuGet Feed Reference

The internal NuGet feed ID is `0cf3d305-b067-4202-995b-1a634ff8d187`. Use in restore tasks:
```yaml
vstsFeed: "0cf3d305-b067-4202-995b-1a634ff8d187/aa78e24d-62e0-41c5-a2dc-1524b161ac92"
```

---

## NuGet Package Pipeline

The SyncService NuGet pipeline (`Pipelines/SyncService/syncservice-nuget-pipeline.yml`) generates API client NuGet packages using NSwag.

### Pipeline Trigger

```yaml
trigger:
  branches:
    include:
      - Development
  paths:
    include:
      - Backend/CDM.NET.SyncService/CDM.NET.SyncService.API/Controllers/*
      - Backend/CDM.NET.SyncService/CDM.NET.SyncService.API/Requests/*
      - Backend/CDM.NET.SyncService/CDM.NET.SyncService.API/Responses/*
      - Pipelines/SyncService/syncservice-nuget-pipeline.yml
```

### Variables

```yaml
variables:
  buildConfiguration: "Release"
  ClientFilename: "SyncServiceClient"
  NugetPackageName: "CDM.NET.SyncService.API.Clients"
  ProjectNameAPI: "CDM.NET.SyncService.API"
  NswagMsbuildLocation: '$env:USERPROFILE\.nuget\packages\nswag.msbuild\13.14.5\tools\Net60'
  NugetSource: "https://pkgs.dev.azure.com/PlanInternational-PlanCRM/CDM.NET/_packaging/CDM.NET/nuget/v3/index.json"
  NewtonsoftJsonVersion: "13.0.1"
  SystemComponentModelAnnotationsVersion: "5.0.0"
  DotnetFramework: "net6.0"
```

### Steps (template-based)

The pipeline uses two templates:
1. `Templates/create-api-client-steps.yml` — NSwag client generation
2. `Templates/nuget-push-steps.yml` — pack and push to Azure Artifacts

### NSwag Client Generation Process

The `create-api-client-steps.yml` template:
1. Restores the API project
2. Builds the API project
3. Runs `dotnet nswag aspnetcore2swagger` to generate OpenAPI spec
4. Runs `dotnet nswag swagger2csclient` to generate C# client
5. Creates a classlib project for the NuGet package
6. Copies the generated client into the classlib

---

## Pipeline Templates

Reusable templates are in `Pipelines/Templates/`:

| Template | Purpose | Variables Used |
|----------|---------|----------------|
| `api-publish-steps.yml` | Restore, test, publish .NET API | `ProjectFolder`, `ProjectNameAPI`, `BuildConfiguration` |
| `create-api-client-steps.yml` | Generate NSwag client, create classlib | `ProjectNameAPI`, `ClientFilename`, `NugetPackageName`, `DotnetFramework`, `NewtonsoftJsonVersion`, `SystemComponentModelAnnotationsVersion` |
| `nuget-push-steps.yml` | Pack and push NuGet package | `NugetPackageName` |

### Using Templates

```yaml
steps:
  - template: Templates/api-publish-steps.yml
  - template: Templates/create-api-client-steps.yml
```

---

## Variable Groups

### Shared Variable Groups

| Group Name | Purpose |
|-----------|---------|
| `ACR-credentials` | Container registry auth: `CONTAINER_REGISTRY_USERNAME`, `CONTAINER_REGISTRY_PASSWORD` |
| `<prefix>-dev` | Dev environment config |
| `<prefix>-test` | Test environment config |
| `<prefix>-prod` | Production environment config |

### Creating Variable Groups

```bash
ORG="https://dev.azure.com/PlanInternational-PlanCRM"
PROJECT="PlanBackOffice"

# Create variable group
az pipelines variable-group create \
  --name "<prefix>-dev" \
  --variables placeholder=temp \
  --org $ORG --project $PROJECT

# Note the group ID, then add variables:
az pipelines variable-group variable create \
  --group-id <ID> \
  --name "ConnectionStrings__Bisnode" \
  --value '<connection-string>' \
  --org $ORG --project $PROJECT

# For secrets:
az pipelines variable-group variable create \
  --group-id <ID> \
  --name "AzureAd__ClientSecret" \
  --value '<secret>' \
  --secret true \
  --org $ORG --project $PROJECT

# Delete placeholder after adding real variables:
az pipelines variable-group variable delete \
  --group-id <ID> \
  --name "placeholder" \
  --org $ORG --project $PROJECT --yes
```

### Variable Classification

| Category | Examples | Secret? | Per-Environment? |
|----------|----------|---------|------------------|
| Connection strings | `ConnectionStrings__Bisnode`, `ConnectionStrings__Cdm` | Yes | Yes |
| Auth secrets | `AzureAd__ClientSecret` | Yes | Same across envs |
| Auth IDs | `AzureAd__ClientId`, `AzureAd__ScopeName`, `AzureAd__ScopeURI` | No | Same across envs |
| Service endpoints | `SyncService__URI`, `PdfGenerator__URI`, `TemplateRenderer__URI` | No | Yes (hostname changes) |
| API keys | `<Service>__ApiKey` | Yes | Yes |

### Service URI Pattern Across Environments

```
<service>-<env>:<port>
Example:
  SyncService: http://cdmnetsyncserviceapi-dev:8080/  (dev)
               http://cdmnetsyncserviceapi-test:8081/  (test)
               http://cdmnetsyncserviceapi-prod:8082/  (prod)
```

### Listing & Verifying Variable Groups

```bash
# List variable groups
az pipelines variable-group list --org $ORG --project $PROJECT --output table

# Show group details
az pipelines variable-group show --group-id <ID> --org $ORG --project $PROJECT

# Show just the variable names
az pipelines variable-group show --group-id <ID> --org $ORG --project $PROJECT \
  --query "variables | keys(@)" -o json
```

---

## Work Item Management

### Work Item Hierarchy

```
Epic (e.g., 28220: Entra ID Migration)
  └─ Product Backlog Item (PBI) - Feature/Phase
      └─ Task - Specific work item
```

### Custom Fields specific to PlanCRM

| Field | Description |
|-------|-------------|
| `Custom.InitialEstimation` | Initial Estimation (hours) |
| `Custom.Whatisbeingdelivered` | What needs to be delivered |
| `Microsoft.VSTS.Scheduling.RemainingWork` | Remaining Work (hours) |
| `Microsoft.VSTS.Scheduling.CompletedWork` | Completed Work (hours) |
| `Microsoft.VSTS.Scheduling.OriginalEstimate` | Original Estimate (hours) |
| `Microsoft.VSTS.Scheduling.Effort` | Effort (story points or hours) |
| `System.Description` | Main Description (supports HTML) |
| `Microsoft.VSTS.Common.AcceptanceCriteria` | Acceptance Criteria |

### Querying Work Items

```bash
# Show specific work item
az boards work-item show --id 28222 --org $ORG --output json

# Find all custom fields
az boards work-item show --id 28222 --org $ORG --output json \
  | jq '.fields | keys[]' | grep "Custom\."

# Check estimation fields
az boards work-item show --id 28222 --org $ORG --output json | jq '{
  InitialEstimation: .fields["Custom.InitialEstimation"],
  RemainingWork: .fields["Microsoft.VSTS.Scheduling.RemainingWork"]
}'

# Query by iteration path
az boards query --wiql "SELECT [ID], [Title] FROM WorkItems \
  WHERE [Iteration Path] = 'PlanCRM\\Phase 3'" --org $ORG
```

### Updating Work Items

```bash
# Single field
az boards work-item update --id 28222 \
  --org $ORG \
  --fields "Custom.InitialEstimation=8" \
  --output table

# Multiple fields
az boards work-item update --id 28222 \
  --org $ORG \
  --fields "Custom.InitialEstimation=8" \
          "Microsoft.VSTS.Scheduling.RemainingWork=8" \
  --output table

# HTML description (Azure DevOps uses HTML, not Markdown)
az boards work-item update --id 28222 \
  --org $ORG \
  --description "<h2>Title</h2><p>Content with <strong>HTML</strong></p>" \
  --output table
```

### Downloading Attachments

```bash
# Get work item to find attachment IDs in relations
az boards work-item show --id 23598 --org $ORG --output json > work_item.json

# Download attachment
az devops invoke --org $ORG \
  --area wit --resource attachments \
  --route-parameters id=<ATTACHMENT_GUID> \
  --http-method GET \
  --out-file output.sql
```

### Creating Comprehensive PBIs

PBIs in Azure DevOps must use **HTML** formatting (not Markdown). Include these sections:
1. Phase Overview (duration, effort, executive summary)
2. Business Context (current state, why needed, expected outcomes)
3. Technical Scope (detailed breakdown, step-by-step guidance, code examples)
4. Security & Compliance (best practices, what NOT to do)
5. Acceptance Criteria (☐ checklist format, measurable success criteria)
6. Dependencies & Prerequisites (access, tools, knowledge)
7. Reference Documentation (links, related work items)

### Work Item Best Practices

**DO:**
- ✅ Use HTML formatting in Description and custom fields (not Markdown)
- ✅ Set `Custom.InitialEstimation` = `RemainingWork` for new tasks
- ✅ Include comprehensive acceptance criteria with ☐ checkboxes
- ✅ Reference documentation paths (e.g., `/docs/EntraID-Migration-Plan.md`)
- ✅ Use `<code>` for inline code, `<pre>` for code blocks
- ✅ Link tasks to parent PBIs, PBIs to Epic
- ✅ Set iteration path for sprint planning

**DON'T:**
- ❌ Use Markdown (Azure DevOps needs HTML)
- ❌ Set `RemainingWork` < `InitialEstimation` on new/unstarted tasks
- ❌ Forget to update `Custom.Whatisbeingdelivered`
- ❌ Use placeholder text like "TODO" or "TBD"

### Estimation Guidelines

```
New Task:        InitialEstimation=8, Remaining=8,  Completed=0
After 3 hours:   InitialEstimation=8, Remaining=5,  Completed=3
Complete:        InitialEstimation=8, Remaining=0,  Completed=8
```

---

## Azure CLI Operations

### Basic Setup

```bash
# Install/update Azure DevOps extension
az extension add --name azure-devops
az extension update --name azure-devops

# Configure defaults (one-time)
az devops configure --defaults \
  organization=https://dev.azure.com/PlanInternational-PlanCRM \
  project=PlanBackOffice

# Verify
az devops configure --list

# List projects
az devops project list --output table
```

### Pipeline Management

```bash
# List pipelines
az pipelines list --output table

# Show a specific pipeline
az pipelines show --id <pipeline-id> --output table

# Run a pipeline
az pipelines run --id <pipeline-id> --branch develop --output table

# Show build details
az pipelines build show --id <build-id> --output table

# List builds for a pipeline
az pipelines build list --pipeline-id <pipeline-id> --output table

# Download build artifacts
az pipelines build artifact download --build-id <build-id> \
  --artifact-name drop --path ./downloads
```

### Agent Pool Management

```bash
# List agent pools
az pipelines pool list --output table

# Show pool details
az pipelines pool show --id <pool-id>

# List agents in a pool
az pipelines agent list --pool-id <pool-id> --output table
```

### Repository & Branch

```bash
# List repos
az repos list --output table

# Create a new branch from main
az repos ref create --name refs/heads/feature/my-feature \
  --object-id $(git rev-parse main) --repository "PlanBackOffice"
```

### NuGet Feed

```bash
# List feeds
az artifacts universal feed list --output table

# Show feed details
az artifacts universal feed show --feed "CDM.NET"

# List packages in feed
az artifacts universal list --feed "CDM.NET" --output table
```

---

## Troubleshooting & Common Issues

### 1. NuGet Warnings in Build

The project permanently suppresses two NuGet warnings in `Directory.Build.props`:
- `NU1608` — Elsa v2 has no .NET 10 release
- `NU1510` — System.Security.Cryptography.Xml pinned for vulnerability fix

If you see these in build output, they are expected and safe to ignore.

### 2. Pinned Transitive Packages

Two transitive packages are pinned repo-wide:
- `System.Security.Cryptography.Xml` v9.0.15
- `NuGet.Packaging` / `NuGet.Protocol` v6.12.5

### 3. TreatWarningsAsErrors

`TreatWarningsAsErrors=true` is set in every `Directory.Build.props`. If a new warning appears during build, either fix the underlying issue or add a `NoWarn` suppression.

### 4. `--env-add` vs `--env`

A common Docker Swarm pipeline mistake:
- `docker service update` → use `--env-add` (NOT `--env`)
- `docker service create` → use `--env` (NOT `--env-add`)

### 5. Variable Group "Must Have at Least One Variable"

Azure DevOps requires at least one variable in a group. When deleting old variables, add a new one first to avoid this error.

### 6. Dot Notation in Environment Variables

`AzureAd.ClientSecret=value` does **not** work as a Docker environment variable for ASP.NET Core config binding. Always use `AzureAd__ClientSecret=value` (double underscore).

### 7. `latest` Tag Policy

The `:latest` Docker tag should only be pushed from the production branch (`main` or `release`), never from `develop`.

### 8. Self-Hosted Agent Image Accumulation

Self-hosted agents accumulate old Docker images. Always add a prune step:
```yaml
$(RUNTIME_CMD) image prune -af --filter "until=168h" || true
```

### 9. Pipeline Branch Conditions

Azure DevOps compares source branches as strings — the branch ref must match exactly:
```yaml
condition: |
  and(
    succeeded(),
    eq(variables['Build.SourceBranch'], 'refs/heads/main')
  )
```
Do not use just `main` — use the full `refs/heads/main`.

### 10. Deploy Stages Should Not Check Out Source

```yaml
steps:
  - checkout: none  # Deploy stages don't need source code
```

### 11. Build Context for Docker

When the Dockerfile is in a subdirectory of the repo root, the build context must match:
```yaml
BUILD_CONTEXT: "Backend/CDM.NET.SyncService"  # Not "."
DOCKERFILE_PATH: "Backend/CDM.NET.SyncService/CDM.NET.SyncService.API/Dockerfile"
```

### 12. Pipeline Not Triggering

Verify the `trigger.paths.include` pattern matches the changed files. Azure DevOps path filters are case-sensitive.

---

## Reference Files

For complete details, refer to these files in the repository:

| File | What it covers |
|------|----------------|
| `Pipelines/azure-pipelines-docker-blazor-Frontend.yml` | Canonical Docker Swarm pipeline template |
| `Pipelines/SyncService/azure-pipelines-docker-syncservice-api.yml` | Backend Docker Swarm pipeline example |
| `Pipelines/SyncService/syncservice-nuget-pipeline.yml` | NuGet package pipeline |
| `Pipelines/Templates/create-api-client-steps.yml` | NSwag client generation template |
| `Pipelines/Templates/nuget-push-steps.yml` | NuGet push template |
| `Pipelines/Templates/api-publish-steps.yml` | API publish template |
| `.github/instructions/docker-swarm-pipeline.instructions.md` | Detailed Docker Swarm pipeline setup guide |
| `.github/instructions/devops-itme-managment.instructions.md` | Work item management guide |
| `Pipelines/azurepipelines-coverage.yml` | Code coverage configuration |

---

## Common Workflows

### Workflow A: Create a New Docker Swarm Pipeline

1. Copy `Pipelines/azure-pipelines-docker-blazor-Frontend.yml`
2. Update all variables in the `variables:` section
3. Update `trigger.paths.include` to match the project folder
4. Update variable group references in each stage
5. Update `--env` / `--env-add` lines to match `appsettings.json`
6. Create 3 variable groups (`-dev`, `-test`, `-prod`)
7. Ensure overlay networks exist on the Swarm cluster

### Workflow B: Create a New NuGet Client Package

1. Add API controller changes that modify the OpenAPI surface
2. Push to `Development` branch
3. The `syncservice-nuget-pipeline.yml` auto-triggers on paths:
   - `Controllers/*`, `Requests/*`, `Responses/*`
4. Pipeline generates NSwag client, packs, and pushes to NuGet feed

### Workflow C: Update Work Item Estimation

```bash
az boards work-item update --id <ID> \
  --org https://dev.azure.com/PlanInternational-PlanCRM \
  --fields "Custom.InitialEstimation=8" \
          "Microsoft.VSTS.Scheduling.RemainingWork=8" \
  --output table
```

### Workflow D: Promote Through Environments

Branch promotion flow:
```
develop ──► Dev (automatic)
master  ──► Dev → Test (manual approval gate at Test)
release ──► Dev → Test → Prod (manual approval at each stage)
```
