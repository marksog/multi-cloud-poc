# Get current Azure context
data "azurerm_subscription" "current" {}
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "acr" {
  name     = "rg-lab-acr"
  location = "eastus"
}

# ACR — equivalent to AWS ECR
resource "azurerm_container_registry" "main" {
  name                = "acrlab${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.acr.name
  location            = azurerm_resource_group.acr.location
  sku                 = "Basic"              # Use Standard in prod (geo-replication, retention)
  admin_enabled       = false               # Never enable admin — use managed identity

  # Enable vulnerability scanning (Microsoft Defender for ACR)
  # Note: Requires Standard or Premium SKU in production
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Managed identity for the workload (the "IAM role" equivalent)
resource "azurerm_user_assigned_identity" "workload" {
  name                = "id-lab-workload"
  resource_group_name = azurerm_resource_group.acr.name
  location            = azurerm_resource_group.acr.location
}

# Grant the managed identity permission to pull from ACR
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"          # Equivalent to ECR GetAuthorizationToken + BatchGetImage
  principal_id         = azurerm_user_assigned_identity.workload.principal_id
}

# Reference existing AKS cluster (from Day 2)
data "azurerm_kubernetes_cluster" "main" {
  name                = "aks-lab-main"
  resource_group_name = "rg-lab-aks"
}

# Federated identity credential — this is the OIDC trust binding
# Equivalent to: aws iam create-role --role-name ... --assume-role-policy-document oidc-trust.json
resource "azurerm_federated_identity_credential" "workload" {
  name                = "fic-lab-workload"
  resource_group_name = azurerm_resource_group.acr.name
  parent_id           = azurerm_user_assigned_identity.workload.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = data.azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:default:workload-sa"
  # Format: system:serviceaccount:<namespace>:<serviceaccount-name>
}

output "acr_login_server"     { value = azurerm_container_registry.main.login_server }
output "managed_identity_client_id" { value = azurerm_user_assigned_identity.workload.client_id }