terraform init && terraform apply -auto-approve

LAW_ID=$(terraform output -raw log_analytics_workspace_id)

# Enable Container Insights on AKS (Azure addon)
az aks enable-addons \
  --addons monitoring \
  --name aks-lab-main \
  --resource-group rg-lab-aks \
  --workspace-resource-id $LAW_ID

# Verify the addon is running
kubectl get pods -n kube-system | grep omsagent
# You should see: omsagent-* (DaemonSet) and omsagent-rs-* (ReplicaSet)