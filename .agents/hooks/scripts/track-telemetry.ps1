# Telemetry tracking hook for Azure Copilot Skills
# Reads JSON input from stdin, tracks relevant events, and publishes via MCP

$ErrorActionPreference = "SilentlyContinue"

# Skip telemetry if opted out
if ($env:AZURE_MCP_COLLECT_TELEMETRY -eq "false") {
    Write-Output '{"continue":true}'
    exit 0
}

# Return success and exit
function Write-Success {
    Write-Output '{"continue":true}'
    exit 0
}

# === Main Processing ===

# Read entire stdin at once - hooks send one complete JSON per invocation
try {
    $rawInput = [Console]::In.ReadToEnd()
}
catch {
    Write-Success
}

# Return success and exit if no input
if ([string]::IsNullOrWhiteSpace($rawInput)) {
    Write-Success
}

# === STEP 1: Read and parse input ===

# Parse JSON input
try {
    $inputData = $rawInput | ConvertFrom-Json
}
catch {
    Write-Success
}

# Extract fields from hook data
# Support Copilot CLI (camelCase), Claude Code (snake_case), and VS Code (snake_case + tool_use_id with __vscode)
$toolName = $inputData.toolName
if (-not $toolName) { $toolName = $inputData.tool_name }

$sessionId = $inputData.sessionId
if (-not $sessionId) { $sessionId = $inputData.session_id }

# Get tool arguments (Copilot CLI: toolArgs, Claude Code / VS Code: tool_input)
$toolInput = $inputData.toolArgs
if (-not $toolInput) { $toolInput = $inputData.tool_input }

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Detect client type
# VS Code: has hook_event_name (like Claude Code) BUT tool_use_id contains "__vscode"
# Claude Code: has hook_event_name, tool_use_id does NOT contain "__vscode"
# Copilot CLI: has toolName/toolArgs (camelCase), no hook_event_name
$hasHookEventName = $inputData.PSObject.Properties.Name -contains "hook_event_name"
$hasToolArgs = $inputData.PSObject.Properties.Name -contains "toolArgs"
$toolUseId = $inputData.tool_use_id
$transcriptPath = $inputData.transcript_path
$isVscodeToolUseId = $toolUseId -and ($toolUseId -match '__vscode')
$isVscodeTranscript = $transcriptPath -and ($transcriptPath -match 'Code')

if ($hasHookEventName -and ($isVscodeToolUseId -or $isVscodeTranscript)) {
    $clientType = "vscode"
}
elseif ($hasHookEventName) {
    $clientType = "claude-code"
}
elseif ($hasToolArgs) {
    $clientType = "copilot-cli"
}
else {
    $clientType = "unknown"
}

# Skip if no tool name found in any format
if (-not $toolName) {
    Write-Success
}

# Helper to extract path from tool input (handles 'path', 'filePath', 'file_path')
function Get-ToolInputPath {
    if ($toolInput.path) { return $toolInput.path }
    if ($toolInput.filePath) { return $toolInput.filePath }
    if ($toolInput.file_path) { return $toolInput.file_path }
    return $null
}

# === STEP 2: Determine what to track for azmcp ===

$shouldTrack = $false
$eventType = $null
$skillName = $null
$azureToolName = $null
$filePath = $null

# Check for skill invocation via 'skill'/'Skill' tool
if ($toolName -eq "skill" -or $toolName -eq "Skill") {
    $skillName = $toolInput.skill
    if ($skillName) {
        $eventType = "skill_invocation"
        $shouldTrack = $true
    }
}

# Check for skill invocation (reading SKILL.md files)
# Copilot CLI: "view", Claude Code: "Read", VS Code: "read_file"
if ($toolName -eq "view" -or $toolName -eq "Read" -or $toolName -eq "read_file") {
    $pathToCheck = Get-ToolInputPath
    if ($pathToCheck) {
        # Normalize path: convert to lowercase, replace backslashes, and squeeze consecutive slashes
        $pathLower = $pathToCheck.ToLower() -replace '\\', '/' -replace '/+', '/'

        # Check for SKILL.md pattern across all clients
        # Copilot CLI: .copilot/...skills/.../SKILL.md
        # Claude Code: .claude/...skills/.../SKILL.md
        # VS Code:     agentPlugins/.../azure-skills/skills/.../SKILL.md
        if ($pathLower -match 'skills/[^/]+/skill\.md') {
            # Normalize path and extract skill name using regex
            $pathNormalized = $pathToCheck -replace '\\', '/' -replace '/+', '/'
            if ($pathNormalized -match '/skills/([^/]+)/SKILL\.md$') {
                $skillName = $Matches[1]
                $eventType = "skill_invocation"
                $shouldTrack = $true
            }
        }
    }
}

# Check for Azure MCP tool invocation
# Copilot CLI: "mcp_azure_*" or "azure-*" prefixes
# Claude Code: "mcp__plugin_azure_azure__*" prefix (double underscores)
if ($toolName) {
    if ($toolName.StartsWith("mcp_azure_") -or $toolName.StartsWith("azure-") -or $toolName.StartsWith("mcp__plugin_azure_azure__") -or $toolName.StartsWith("azure_")) {
        $azureToolName = $toolName
        $eventType = "tool_invocation"
        $shouldTrack = $true
    }
}

# Capture file path from any tool input (only track files in azure skills folder)
# Skip if already matched as SKILL.md skill_invocation — SKILL.md is not a valid file-reference
if (-not $filePath -and -not $skillName) {
    $pathToCheck = Get-ToolInputPath
    if ($pathToCheck) {
        # Normalize path for matching: replace backslashes and squeeze consecutive slashes
        $pathLower = $pathToCheck.ToLower() -replace '\\', '/' -replace '/+', '/'

        # Check if path matches azure skills folder structure
        # Copilot CLI: .copilot/installed-plugins/azure-skills/azure/skills/...
        # Claude Code: .claude/plugins/cache/azure-skills/azure/<version>/skills/...
        # VS Code:     agentPlugins/.../azure-skills/skills/...
        $matchCopilotSkills = $pathLower -match '\.copilot.*installed-plugins.*azure-skills.*azure.*skills'
        $matchClaudeSkills = $pathLower -match '\.claude.*plugins.*cache.*azure-skills.*azure.*skills'
        $matchVscodeSkills = $pathLower -match 'agentplugins.*azure-skills.*skills'
        if ($matchCopilotSkills -or $matchClaudeSkills -or $matchVscodeSkills) {
            # Extract relative path after 'skills/' (handles all three path formats)
            # Copilot/Claude: azure/(<version>/)?skills/(<skill>/<file>)
            # VS Code:        azure-skills/skills/(<skill>/<file>)
            $pathNormalized = $pathToCheck -replace '\\', '/' -replace '/+', '/'

            if ($pathNormalized -match '(?:azure/(?:[0-9]+\.[0-9]+\.[0-9]+/)?skills|azure-skills/skills)/(.+)$') {
                $filePath = $Matches[1]

                if (-not $shouldTrack) {
                    $shouldTrack = $true
                    $eventType = "reference_file_read"
                }
            }
        }
    }
}

# === STEP 3: Publish event ===

if ($shouldTrack) {
    # Build MCP command arguments
    $mcpArgs = @(
        "server", "plugin-telemetry",
        "--timestamp", $timestamp,
        "--client-type", $clientType
    )

    if ($eventType) { $mcpArgs += "--event-type"; $mcpArgs += $eventType }
    if ($sessionId) { $mcpArgs += "--session-id"; $mcpArgs += $sessionId }
    if ($skillName) { $mcpArgs += "--skill-name"; $mcpArgs += $skillName }
    if ($azureToolName) { $mcpArgs += "--tool-name"; $mcpArgs += $azureToolName }
    # Convert forward slashes to backslashes for azmcp allowlist compatibility
    if ($filePath) { $mcpArgs += "--file-reference"; $mcpArgs += ($filePath -replace '/', '\') }

    # Publish telemetry via npx
    try {
        & npx -y @azure/mcp@latest @mcpArgs 2>&1 | Out-Null
    }
    catch { }
}

# Output success to stdout (required by hooks)
Write-Success
