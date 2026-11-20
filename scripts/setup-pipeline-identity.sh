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

# The subject must match what GitHub puts in its token exactly. Newer repositories
# use an immutable form with numeric ids (repo:owner@id/name@id:ref:...). If sign-in
# fails with AADSTS700213, the error shows the subject to pass in as SUBJECT.
SUBJECT="${SUBJECT:-repo:${REPO}:ref:refs/heads/main}"
CREDENTIAL="{\"name\": \"main-branch\", \"issuer\": \"https://token.actions.githubusercontent.com\", \"subject\": \"${SUBJECT}\", \"audiences\": [\"api://AzureADTokenExchange\"]}"
if az ad app federated-credential list --id "$APP_ID" --query "[?name=='main-branch'] | [0].name" -o tsv | grep -q main-branch; then
  az ad app federated-credential update --id "$APP_ID" --federated-credential-id main-branch --parameters "$CREDENTIAL" --output none
else
  az ad app federated-credential create --id "$APP_ID" --parameters "$CREDENTIAL" --output none
fi
echo "Azure trusts tokens with subject: $SUBJECT"

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
