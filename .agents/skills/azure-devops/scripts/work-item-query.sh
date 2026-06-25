#!/usr/bin/env bash
# Azure DevOps Work Item Management Script
# Helper functions for querying and updating work items.
#
# Usage: source ./work-item-query.sh  (for functions)
#        ./work-item-query.sh <command> [args...]

set -euo pipefail

ORG="https://dev.azure.com/PlanInternational-PlanCRM"
PROJECT="PlanBackOffice"

show_help() {
  echo "Azure DevOps Work Item Manager"
  echo ""
  echo "Commands:"
  echo "  show <id>                    Show work item details"
  echo "  custom-fields <id>           Show custom fields for a work item"
  echo "  estimates <id>               Show estimation fields"
  echo "  update <id> <field=value>    Update a field"
  echo "  query <wiql>                 Run a WIQL query"
  echo "  attachments <id>             List attachment URLs"
  echo "  download-attachment <id> <file>  Download attachment"
}

case "${1:-help}" in
  show)
    az boards work-item show --id "$2" --org "$ORG" --output json
    ;;
  custom-fields)
    az boards work-item show --id "$2" --org "$ORG" --output json \
      | jq '.fields | keys[]' | grep "Custom\."
    ;;
  estimates)
    az boards work-item show --id "$2" --org "$ORG" --output json | jq '{
      InitialEstimation: .fields["Custom.InitialEstimation"],
      RemainingWork: .fields["Microsoft.VSTS.Scheduling.RemainingWork"],
      CompletedWork: .fields["Microsoft.VSTS.Scheduling.CompletedWork"],
      Effort: .fields["Microsoft.VSTS.Scheduling.Effort"],
      OriginalEstimate: .fields["Microsoft.VSTS.Scheduling.OriginalEstimate"]
    }'
    ;;
  update)
    shift 2
    FIELDS=""
    for kv in "$@"; do
      FIELDS="$FIELDS $kv"
    done
    az boards work-item update --id "$2" --org "$ORG" --fields $FIELDS --output table
    ;;
  query)
    az boards query --wiql "$2" --org "$ORG" --output table
    ;;
  attachments)
    az boards work-item show --id "$2" --org "$ORG" --output json \
      | jq '.relations[] | select(.rel == "AttachedFile") | {url, id: .attributes.id, name: .attributes.name}'
    ;;
  download-attachment)
    ATTACHMENT_ID=$(az boards work-item show --id "$2" --org "$ORG" --output json \
      | jq -r '.relations[] | select(.rel == "AttachedFile") | .url' \
      | grep -oP '[a-f0-9-]{36}$' | head -1)
    if [ -n "$ATTACHMENT_ID" ]; then
      az devops invoke --org "$ORG" \
        --area wit --resource attachments \
        --route-parameters id="$ATTACHMENT_ID" \
        --http-method GET \
        --out-file "${3:-attachment.bin}"
      echo "Downloaded to ${3:-attachment.bin}"
    else
      echo "No attachment found for work item $2"
    fi
    ;;
  help|*)
    show_help
    ;;
esac
