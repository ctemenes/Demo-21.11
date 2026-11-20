#!/usr/bin/env bash
# One-off: gives the GitHub pipeline its own Azure identity, with no stored secret.
# GitHub proves who it is with a short-lived token (OpenID Connect) and Azure trusts
# only the main branch of this one repository. Run once from a signed-in shell.
set -euo pipefail

REPO="${REPO:-ctemenes/Demo-21.11}"
RG="${RG:-rg-service-request-integration-dev}"
NAME="${NAME:-github-service-request-integration}"

APP_ID="$(az ad app list --display-name "$NAME" --query '[0].appId' -o tsv)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(az ad app create --display-name "$NAME" --query appId -o tsv)"
  az ad sp create --id "$APP_ID" --output none
fi
SP_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv)"

if ! az ad app federated-credential list --id "$APP_ID" --query "[?name=='main-branch'] | [0].name" -o tsv | grep -q main-branch; then
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"main-branch\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${REPO}:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
fi

# Scoped to this one resource group. Owner is needed because the Bicep template
# creates role assignments for the Function App's identity.
RG_ID="$(az group show -n "$RG" --query id -o tsv)"
for role in "Owner" "Storage Blob Data Reader" "Storage Blob Delegator"; do
  az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$RG_ID" --output none 2>/dev/null || true
done

cat <<SUMMARY
Pipeline identity ready. Set these as repository variables (they are ids, not secrets):
  AZURE_CLIENT_ID       = $APP_ID
  AZURE_TENANT_ID       = $(az account show --query tenantId -o tsv)
  AZURE_SUBSCRIPTION_ID = $(az account show --query id -o tsv)
  AZURE_RESOURCE_GROUP  = $RG
SUMMARY
