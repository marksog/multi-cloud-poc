helm uninstall monitoring -n monitoring
az aks disable-addons --addons monitoring --name aks-lab-main --resource-group rg-lab-aks
terraform destroy -auto-approve