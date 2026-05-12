#!/usr/bin/env bash
set -euo pipefail

# Set variables
LOCATION="eastus"
STATE_RG="rg-tfstate"
# Storage account names: 3-24 chars, lowercase letters and numbers only, globally unique
STORAGE_ACCOUNT="mainstterraform$(date +%s | tail -c 8)"
CONTAINER_NAME="tfstate"

echo "=== Creating remote state resources ==="
echo "Storage account: $STORAGE_ACCOUNT"

# Ensure Microsoft.Storage provider is available in this subscription
az provider register --namespace Microsoft.Storage --wait --output none

# Create resource group for state
az group create \
  --name $STATE_RG \
  --location $LOCATION \
  --output table

# Create storage account
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $STATE_RG \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --output table

# Enable blob versioning (lets you recover previous state files)
az storage account blob-service-properties update \
  --account-name $STORAGE_ACCOUNT \
  --resource-group $STATE_RG \
  --enable-versioning true

# Create the state container
az storage container create \
  --name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode login \
  --output table

# SAVE THIS VALUE — you need it in every backend.tf
echo ""
echo "=== SAVE THIS ==="
echo "STORAGE_ACCOUNT=$STORAGE_ACCOUNT"
echo "CONTAINER_NAME=$CONTAINER_NAME"
echo "==============="