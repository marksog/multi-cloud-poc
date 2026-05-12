terraform init && terraform apply -auto-approve

KV_NAME=$(terraform output -raw key_vault_name)
TENANT_ID=$(terraform output -raw tenant_id)
IDENTITY_CLIENT_ID=$(terraform output -raw identity_client_id)

# Install Secrets Store CSI Driver + Azure Key Vault provider via Helm
helm repo add csi-secrets-store-provider-azure \
  https://azure.github.io/secrets-store-csi-driver-provider-azure/charts

helm install csi-secrets-store \
  csi-secrets-store-provider-azure/csi-secrets-store-provider-azure \
  --namespace kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true \
  --set rotationPollInterval=2m

# Verify driver is running
kubectl get pods -n kube-system | grep csi