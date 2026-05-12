output "cluster_name" {
	value = azurerm_kubernetes_cluster.main.name
}

output "resource_group" {
	value = azurerm_resource_group.aks.name
}

output "kube_config_raw" {
	value     = azurerm_kubernetes_cluster.main.kube_config_raw
	sensitive = true
}

output "oidc_issuer_url" {
	value = azurerm_kubernetes_cluster.main.oidc_issuer_url
}