terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
  backend "azurerm" {
    subscription_id      = "e3bda1e9-e6e9-45a5-b2ee-d3d7a754b594"
    resource_group_name  = "rg-tfstate"
    storage_account_name = "mainstterraform8517515"
    container_name       = "tfstate"
    key                  = "day4_kvs/terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azurerm_client_config" "current" {}

data "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-lab-main"
  resource_group_name = "rg-lab-aks"
}

data "azurerm_resource_group" "aks" {
  name = "rg-lab-aks"
}

resource "azurerm_resource_group" "kv" {
  name     = "rg-lab-keyvault"
  location = "eastus"
}

# Key Vault — equivalent to AWS Secrets Manager + Parameter Store combined
resource "azurerm_key_vault" "main" {
  name                = "kv-lab-${random_string.suffix.result}"
  location            = azurerm_resource_group.kv.location
  resource_group_name = azurerm_resource_group.kv.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Enable for template deployments (needed by CSI driver)
  enabled_for_template_deployment = true

  # Soft delete is on by default — protects against accidental deletion
  soft_delete_retention_days = 7
  purge_protection_enabled   = false # Set true in prod

  # Access policies — grant yourself full access
  access_policy {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    object_id          = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "List", "Set", "Delete", "Recover", "Purge"]
    key_permissions    = ["Get", "List", "Create", "Delete"]
  }
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Create test secrets
resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = "super-secret-password-123"
  key_vault_id = azurerm_key_vault.main.id
}

resource "azurerm_key_vault_secret" "api_key" {
  name         = "api-key"
  value        = "api-key-abc123-do-not-commit"
  key_vault_id = azurerm_key_vault.main.id
}

# Managed identity for the CSI driver workload
resource "azurerm_user_assigned_identity" "csi" {
  name                = "id-lab-csi-driver"
  resource_group_name = azurerm_resource_group.kv.name
  location            = azurerm_resource_group.kv.location
}

# Grant the identity read access to Key Vault
resource "azurerm_key_vault_access_policy" "csi" {
  key_vault_id       = azurerm_key_vault.main.id
  tenant_id          = data.azurerm_client_config.current.tenant_id
  object_id          = azurerm_user_assigned_identity.csi.principal_id
  secret_permissions = ["Get"]
}

# Federated credential for workload identity
resource "azurerm_federated_identity_credential" "csi" {
  name                = "fic-lab-csi"
  resource_group_name = azurerm_resource_group.kv.name
  parent_id           = azurerm_user_assigned_identity.csi.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = data.azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject             = "system:serviceaccount:default:csi-sa"
}

output "key_vault_name" {
  value = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.main.vault_uri
}

output "identity_client_id" {
  value = azurerm_user_assigned_identity.csi.client_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}