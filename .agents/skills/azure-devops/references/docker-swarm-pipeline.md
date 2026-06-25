# Docker Swarm Pipeline Reference

This reference summarizes the Docker Swarm CI/CD pipeline pattern used in PlanBackOffice.

## Pipeline Structure

```yaml
stages:
  - stage: Build           # Microsoft-hosted ubuntu-latest
  - stage: DeployDev       # Self-hosted NNO-pipe/docker01
  - stage: DeployTest      # Self-hosted, manual approval
  - stage: DeployProd      # Self-hosted, manual approval
```

## Branch → Environment Mapping

| Branch | Build | Dev | Test | Prod |
|--------|-------|-----|------|------|
| `develop` | ✅ | ✅ | ❌ | ❌ |
| `master` | ✅ | ✅ | ✅ | ❌ |
| `release` | ✅ | ✅ | ✅ | ✅ |

## Key Variables

```yaml
variables:
  PROJECT_NAME: "cdm-web"                              # Swarm service prefix
  PROJECT_DISPLAY_NAME: "cdm-web"                      # Human-readable
  DOTNET_VERSION: "10.0.x"                             # SDK version
  PROJECT_PATH: "Frontend/Web/Web.csproj"              # .csproj path
  DOCKERFILE_PATH: "Frontend/Dockerfile"               # Dockerfile path
  BUILD_CONTEXT: "."                                   # Docker build context
  IMAGE_NAME: "plandockerapps.azurecr.io/blazor-frontend"  # ACR image
  DEV_PORT: "8098"       TEST_PORT: "8099"     PROD_PORT: "8100"
  CONTAINER_PORT: "8098"                               # Internal container port
  NETWORK_PREFIX: "cdm"                                # Overlay network
  SERVICE_REPLICAS: "1"                                # Swarm replicas
  BUILD_AGENT_POOL: "ubuntu-latest"
  DEPLOY_AGENT_POOL: "NNO-pipe"
  DEPLOY_AGENT_NAME: "docker01"
```

## Docker Swarm Commands

### Create a new service
```bash
docker service create \
  --with-registry-auth \
  --name <service>-<env> \
  --publish <HOST_PORT>:<CONTAINER_PORT> \
  --env "ASPNETCORE__ENVIRONMENT=<Env>" \
  --env "ASPNETCORE__FORWARDEDHEADERS_ENABLED=true" \
  --env "ASPNETCORE__URLS=http://+:<CONTAINER_PORT>" \
  --env "Key=Value" \
  --restart-condition on-failure \
  --replicas <N> \
  --network <prefix>-<env> \
  --label "environment=<env>" \
  --health-cmd "curl -f http://localhost:<CONTAINER_PORT>/health || exit 1" \
  --health-interval 30s --health-retries 3 --health-start-period 30s \
  <REGISTRY>/<IMAGE>:<TAG>
```

### Update an existing service
```bash
docker service update \
  --with-registry-auth \
  --image <REGISTRY>/<IMAGE>:<TAG> \
  --replicas <N> \
  --env-add "ASPNETCORE__ENVIRONMENT=<Env>" \
  --env-add "Key=Value" \
  --label-add "version=<TAG>" \
  --health-cmd "curl -f http://localhost:<CONTAINER_PORT>/health || exit 1" \
  --health-interval 30s --health-retries 3 --health-start-period 30s \
  --update-failure-action rollback \
  --update-order start-first \
  <SERVICE_NAME>
```

### Service management
```bash
docker service ls                                    # List all services
docker service ps <name>                             # List tasks/replicas
docker service logs <name>                           # View logs
docker service scale <name>=<N>                      # Scale replicas
docker service inspect <name>                        # Detailed info
docker service rm <name>                             # Remove service
docker service update --image <img>:<tag> <name>     # Quick image update
```

## Health Check Setup

### Program.cs
```csharp
builder.Services.AddHealthChecks();
// ... after app.MapControllers() or app.MapRazorPages()
app.MapHealthChecks("/health");
```

### Dockerfile (add curl)
```dockerfile
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
```

## Overlay Networks

Create once before first deploy:
```bash
docker network create --driver overlay <NETWORK_PREFIX>-dev
docker network create --driver overlay <NETWORK_PREFIX>-test
docker network create --driver overlay <NETWORK_PREFIX>-prod
```
