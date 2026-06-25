# NSwag Client Generation Reference

The SyncService NuGet pipeline generates typed API clients from ASP.NET Core controllers using NSwag.

## Process Flow

```
ASP.NET Core Controllers
       │
       ▼
dotnet nswag aspnetcore2swagger  ──► OpenAPI JSON spec
       │
       ▼
dotnet nswag swagger2csclient    ──► C# HttpClient client
       │
       ▼
dotnet pack                      ──► NuGet .nupkg
       │
       ▼
dotnet nuget push                ──► Azure Artifacts feed
```

## Pipeline Variables

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `ClientFilename` | Base name for generated files | `SyncServiceClient` |
| `NugetPackageName` | NuGet package name | `CDM.NET.SyncService.API.Clients` |
| `ProjectNameAPI` | Source API project | `CDM.NET.SyncService.API` |
| `NugetSource` | Feed NuGet source URL | `https://pkgs.dev.azure.com/.../CDM.NET/_packaging/CDM.NET/nuget/v3/index.json` |
| `NewtonsoftJsonVersion` | Newtonsoft.Json dep version | `13.0.1` |
| `SystemComponentModelAnnotationsVersion` | Annotations dep version | `5.0.0` |
| `DotnetFramework` | Target framework for NuGet | `net6.0` |

## Trigger Paths

The NuGet pipeline auto-triggers when these files change:
- `**/Controllers/*` — API endpoint changes
- `**/Requests/*` — Request DTO changes
- `**/Responses/*` — Response DTO changes
- `syncservice-nuget-pipeline.yml` — Pipeline definition changes

## Template: create-api-client-steps.yml

```yaml
steps:
  - task: DotNetCoreCLI@2
    displayName: Restore
    inputs:
      command: restore
      projects: "**/$(ProjectNameAPI).csproj"
      vstsFeed: "0cf3d305-b067-4202-995b-1a634ff8d187/aa78e24d-62e0-41c5-a2dc-1524b161ac92"

  - task: DotNetCoreCLI@2
    displayName: Build
    inputs:
      command: "build"
      projects: "**/$(ProjectNameAPI).csproj"

  - powershell: |
      Set-Location "$(Build.SourcesDirectory)\Backend\$(ProjectFolder)\$(ProjectNameAPI)"
      $documentName = "v1"
      dotnet tool restore --ignore-failed-sources

      Write-Host "GENERATING CLIENTS"
      dotnet nswag aspnetcore2swagger /project:$(ProjectNameAPI).csproj /noBuild:true /documentName:v1 /output:$(ClientFilename).json
      Write-Host "Json GENERATED"

      dotnet nswag swagger2csclient /output:$(ClientFilename).cs /namespace:$(NugetPackageName) /InjectHttpClient:true /input:$(ClientFilename).json /GenerateClientInterfaces:true /dateType:System.DateTime /dateTimeType:System.DateTime /useBaseUrl:false
      Write-Host ".cs GENERATED"

      Write-Host "CREATE PACKAGE PROJECT FOLDER"
      dotnet new classlib --name=$(NugetPackageName) --framework=$(DotnetFramework) --output="$(Build.SourcesDirectory)\src\$(NugetPackageName)"

      Set-Location $(Build.SourcesDirectory)\src\$(NugetPackageName)
      del $(Build.SourcesDirectory)\src\$(NugetPackageName)\Class1.cs
      dotnet add package Newtonsoft.Json --version="$(NewtonsoftJsonVersion)" --source="$(NugetSource)"
      dotnet add package System.ComponentModel.Annotations --version="$(SystemComponentModelAnnotationsVersion)" --source="$(NugetSource)"
      dotnet restore

      Write-Host "COPY TO NUGET PACKAGE PROJECT FOLDER"
      Set-Location "$(Build.SourcesDirectory)\Backend\$(ProjectFolder)\$(ProjectNameAPI)"
      Copy-Item "$(ClientFilename).cs" -Destination "$(Build.SourcesDirectory)\src\$(NugetPackageName)"
    displayName: "PowerShell Script"
```

## Template: nuget-push-steps.yml

```yaml
steps:
  - task: DotNetCoreCLI@2
    displayName: "Nuget pack project"
    inputs:
      command: "pack"
      packagesToPack: "$(Build.SourcesDirectory)/src/$(NugetPackageName)/*.csproj"
      versioningScheme: "byBuildNumber"

  - task: DotNetCoreCLI@2
    displayName: "Nuget push project"
    inputs:
      command: push
      publishVstsFeed: "0cf3d305-b067-4202-995b-1a634ff8d187/aa78e24d-62e0-41c5-a2dc-1524b161ac92"
```

## Notes for NSwag

- Generated clients are **build artifacts** — do not edit manually
- Regenerate from contract changes (modify controllers, requests, responses)
- The project uses `net6.0` target framework for NuGet package compatibility
- Dependencies: `Newtonsoft.Json` + `System.ComponentModel.Annotations`
- Generation runs on Windows PowerShell (self-hosted or Microsoft-hosted Windows agent)
