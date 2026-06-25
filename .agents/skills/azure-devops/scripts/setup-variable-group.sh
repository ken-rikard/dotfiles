#!/usr/bin/env bash
# Azure DevOps Variable Group Setup Script
# Creates and populates environment variable groups for a new pipeline.
#
# Usage: ./setup-variable-group.sh <prefix> <environment>
#   <prefix>: Project variable group prefix (e.g., CDM-blazor-frontend)
#   <environment>: dev, test, or prod
#
# Example: ./setup-variable-group.sh CDM-blazor-frontend dev

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <prefix> <environment>"
  echo "Example: $0 CDM-blazor-frontend dev"
  exit 1
fi

PREFIX="$1"
ENV="$2"
GROUP_NAME="${PREFIX}-${ENV}"

ORG="https://dev.azure.com/PlanInternational-PlanCRM"
PROJECT="PlanBackOffice"

echo "🚀 Creating variable group: $GROUP_NAME"
echo "Environment: $ENV"
echo "================================"

# Create variable group with placeholder (required by Azure DevOps)
GROUP_ID=$(az pipelines variable-group create \
  --name "$GROUP_NAME" \
  --variables placeholder=temp \
  --org "$ORG" --project "$PROJECT" \
  --query "id" -o tsv)

echo "✅ Created variable group ID: $GROUP_ID"

# Helper function to add a variable
add_var() {
  local name="$1"
  local value="$2"
  local secret="${3:-false}"

  if [ "$secret" = "true" ]; then
    az pipelines variable-group variable create \
      --group-id "$GROUP_ID" \
      --name "$name" \
      --value "$value" \
      --secret true \
      --org "$ORG" --project "$PROJECT" > /dev/null
    echo "  🔒 Added secret: $name"
  else
    az pipelines variable-group variable create \
      --group-id "$GROUP_ID" \
      --name "$name" \
      --value "$value" \
      --org "$ORG" --project "$PROJECT" > /dev/null
    echo "  ✅ Added: $name"
  fi
}

# ── Auth variables (same across environments) ──
# These values stay the same in dev, test, and prod
# ⚠️ Replace with actual values!
add_var "AzureAd__ClientId"         "<Azure AD Client ID>"
add_var "AzureAd__ClientSecret"     "<Azure AD Client Secret>" true
add_var "AzureAd__ScopeName"        "<Scope Name>"
add_var "AzureAd__ScopeURI"         "<Scope URI>"

# ── Service endpoints (change hostname per environment) ──
# ⚠️ Adjust based on actual service ports and names
case "$ENV" in
  dev)
    add_var "SyncService__URI"        "http://cdmnetsyncserviceapi-dev:8080/"
    add_var "PdfGenerator__URI"       "http://planpdfgenerator-dev:8086/"
    add_var "TemplateRenderer__URI"   "https://frontend-dev.pbo.plan-norge.no:8098/"
    add_var "ConnectionStrings__Bisnode"  "<dev connection string>" true
    add_var "ConnectionStrings__Cdm"      "<dev connection string>" true
    ;;
  test)
    add_var "SyncService__URI"        "http://cdmnetsyncserviceapi-test:8081/"
    add_var "PdfGenerator__URI"       "http://planpdfgenerator-test:8087/"
    add_var "TemplateRenderer__URI"   "https://frontend-test.pbo.plan-norge.no:8099/"
    add_var "ConnectionStrings__Bisnode"  "<test connection string>" true
    add_var "ConnectionStrings__Cdm"      "<test connection string>" true
    ;;
  prod)
    add_var "SyncService__URI"        "http://cdmnetsyncserviceapi-prod:8082/"
    add_var "PdfGenerator__URI"       "http://planpdfgenerator-prod:8088/"
    add_var "TemplateRenderer__URI"   "https://frontend-prod.pbo.plan-norge.no:8100/"
    add_var "ConnectionStrings__Bisnode"  "<prod connection string>" true
    add_var "ConnectionStrings__Cdm"      "<prod connection string>" true
    ;;
esac

# Delete the placeholder variable
az pipelines variable-group variable delete \
  --group-id "$GROUP_ID" \
  --name "placeholder" \
  --org "$ORG" --project "$PROJECT" --yes > /dev/null

echo ""
echo "✅ Variable group '$GROUP_NAME' created with $(az pipelines variable-group show --group-id $GROUP_ID --org $ORG --project $PROJECT --query 'length(variables)') variables"
echo ""
echo "📋 Verify:"
echo "   az pipelines variable-group show --group-id $GROUP_ID --org \"$ORG\" --project \"$PROJECT\" --query \"variables | keys(@)\" -o json"
