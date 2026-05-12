terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
  }
  backend "azurerm" {
    subscription_id      = "e3bda1e9-e6e9-45a5-b2ee-d3d7a754b594"
    resource_group_name  = "rg-tfstate"
    storage_account_name = "mainstterraform8517515"
    container_name       = "tfstate"
    key                  = "day5_monitor_container_grafana/terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-lab-main"
  resource_group_name = "rg-lab-aks"
}

resource "azurerm_resource_group" "monitoring" {
  name     = "rg-lab-monitoring"
  location = "eastus"
}

# Log Analytics Workspace — equivalent to AWS CloudWatch Log Groups but centralized
resource "azurerm_log_analytics_workspace" "main" {
  name                = "law-lab-main"
  location            = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  sku                 = "PerGB2018"
  retention_in_days   = 30 # 90 in prod
}

# Container Insights = Azure's equivalent of CloudWatch Container Insights
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "aks-diagnostics"
  target_resource_id         = data.azurerm_kubernetes_cluster.aks.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "kube-audit" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Azure Monitor workspace for Prometheus metrics
resource "azurerm_monitor_workspace" "main" {
  name                = "amw-lab-main"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
}

# Link AKS to Azure Monitor for managed Prometheus scraping
resource "azurerm_monitor_data_collection_rule" "aks_prometheus" {
  name                = "dcr-lab-aks-prometheus"
  resource_group_name = azurerm_resource_group.monitoring.name
  location            = azurerm_resource_group.monitoring.location
  kind                = "Linux"

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.main.id
      name               = "MonitoringAccount"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount"]
  }

  data_sources {
    prometheus_forwarder {
      name    = "PrometheusDataSource"
      streams = ["Microsoft-PrometheusMetrics"]
    }
  }
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.main.id
}

output "monitor_workspace_id" {
  value = azurerm_monitor_workspace.main.id
}