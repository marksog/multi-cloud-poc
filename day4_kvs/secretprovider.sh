#!/usr/bin/env bash
set -euo pipefail

# Get outputs from Terraform
KV_NAME=$(terraform output -raw key_vault_name)
TENANT_ID=$(terraform output -raw tenant_id)
IDENTITY_CLIENT_ID=$(terraform output -raw identity_client_id)

# Create ServiceAccount
kubectl apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: csi-sa
  namespace: default
  annotations:
    azure.workload.identity/client-id: "${IDENTITY_CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"
EOF

# Create SecretProviderClass — tells CSI driver WHAT to fetch from Key Vault
kubectl apply -f - << EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-kv-secrets
  namespace: default
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"
    clientID: "${IDENTITY_CLIENT_ID}"
    keyvaultName: "${KV_NAME}"
    objects: |
      array:
        - |
          objectName: db-password
          objectType: secret
          objectVersion: ""
        - |
          objectName: api-key
          objectType: secret
          objectVersion: ""
    tenantId: "${TENANT_ID}"
  # This syncs secrets to a Kubernetes Secret object as well
  secretObjects:
  - secretName: app-secrets
    type: Opaque
    data:
    - objectName: db-password
      key: DB_PASSWORD
    - objectName: api-key
      key: API_KEY
EOF

# Deploy a pod that mounts the secrets
kubectl apply -f - << EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-keyvault
  namespace: default
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: csi-sa
  containers:
  - name: app
    image: mcr.microsoft.com/azure-cli
    command: ["sh", "-c", "cat /mnt/secrets/db-password && echo && sleep 3600"]
    volumeMounts:
    - name: secrets-store
      mountPath: /mnt/secrets
      readOnly: true
  volumes:
  - name: secrets-store
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: "azure-kv-secrets"
EOF

# Wait then verify
kubectl wait --for=condition=Ready pod/test-keyvault --timeout=60s
kubectl logs test-keyvault
# Should print: super-secret-password-123

# Test rotation: update the secret in Key Vault
az keyvault secret set \
  --vault-name $KV_NAME \
  --name db-password \
  --value "rotated-password-456"

# Wait 2 minutes (rotation poll interval), then check
sleep 120
kubectl exec test-keyvault -- cat /mnt/secrets/db-password
# Should now show: rotated-password-456