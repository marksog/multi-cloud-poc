resource "azurerm_resource_group" "aks" {
  name     = "rg-${var.prefix}-aks"
  location = var.location
  tags     = { managed_by = "terraform", day = "02" }
}

# VNet for AKS — Azure CNI requires pre-created subnets
resource "azurerm_virtual_network" "aks" {
  name                = "vnet-${var.prefix}-aks"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
}

# System node pool subnet — nodes get IPs from here
resource "azurerm_subnet" "system_nodes" {
  name                 = "snet-system-nodes"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = ["10.1.1.0/24"]
}

# User node pool subnet
resource "azurerm_subnet" "user_nodes" {
  name                 = "snet-user-nodes"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = ["10.1.2.0/24"]
}

# Managed identity for AKS — equivalent to AWS EC2 Instance Profile
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.prefix}-aks"
  resource_group_name = azurerm_resource_group.aks.name
  location            = azurerm_resource_group.aks.location
}

# AKS cluster
resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.prefix}-main"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "${var.prefix}-aks"
  kubernetes_version  = var.kubernetes_version

  # SYSTEM node pool — runs kube-system pods ONLY
  # Never run workloads here (use user node pool)
  default_node_pool {
    name                = "system"
    node_count          = var.system_node_count
    vm_size             = "Standard_B2s"       # 2 vCPU, 4GB RAM — cheapest for lab
    vnet_subnet_id      = azurerm_subnet.system_nodes.id
    type                = "VirtualMachineScaleSets"
    node_labels         = { "node-role" = "system" }
    only_critical_addons_enabled = true        # Forces user workloads to user pool
  }

  # Network — Azure CNI gives each pod a real VNet IP (vs kubenet which NATs)
  # This is the production choice — pods routable from anywhere in VNet
  network_profile {
    network_plugin     = "azure"               # Azure CNI
    network_policy     = "calico"              # Pod-level firewall (like AWS Network Policy)
    load_balancer_sku  = "standard"
    service_cidr       = "10.2.0.0/24"        # Must not overlap with VNet
    dns_service_ip     = "10.2.0.10"
  }

  # Managed identity (no service principal credentials to rotate)
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # Azure AD integration for kubectl access
  azure_active_directory_role_based_access_control {
    managed            = true
    azure_rbac_enabled = true
  }

  # Enable workload identity (equivalent to AWS IRSA)
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  tags = { managed_by = "terraform", day = "02" }
}

# USER node pool — where your actual workloads run
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_B2s"
  vnet_subnet_id        = azurerm_subnet.user_nodes.id

  # Auto-scaling — equivalent to AWS Cluster Autoscaler or Karpenter
  enable_auto_scaling = true
  min_count           = var.user_node_count_min
  max_count           = var.user_node_count_max
  node_count          = var.user_node_count_min

  node_labels = { "node-role" = "user" }

  # Taint to keep system pods off this pool (complement to system pool's critical-only flag)
  node_taints = []

  tags = { managed_by = "terraform" }
}