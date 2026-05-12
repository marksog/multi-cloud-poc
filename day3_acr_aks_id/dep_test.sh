ACR_NAME=$(terraform output -raw acr_login_server | cut -d'.' -f1)
IDENTITY_CLIENT_ID=$(terraform output -raw managed_identity_client_id)

# Build and push a test image (uses your local Docker)
cat > Dockerfile << 'EOF'
FROM python:3.11-alpine
WORKDIR /app
RUN echo 'import time; print("Hello from ACR!"); time.sleep(3600)' > app.py
CMD ["python", "app.py"]
EOF

az acr login --name $ACR_NAME
docker buildx build --platform linux/amd64 -t ${ACR_NAME}.azurecr.io/test-app:v2 --push .
# docker build -t ${ACR_NAME}.azurecr.io/test-app:v2 .
# docker push ${ACR_NAME}.azurecr.io/test-app:v2

# Create Kubernetes ServiceAccount with Workload Identity annotation
# This is the equivalent of annotating with eks.amazonaws.com/role-arn
cat > workload-sa.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-sa
  namespace: default
  annotations:
    azure.workload.identity/client-id: "${IDENTITY_CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"
EOF
kubectl apply -f workload-sa.yaml

# Deploy a pod using the service account
cat > test-pod.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-workload-identity
  namespace: default
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: workload-sa
  containers:
  - name: app
    image: ${ACR_NAME}.azurecr.io/test-app:v2
    imagePullPolicy: Always
EOF
kubectl apply -f test-pod.yaml

# Verify pod runs (pulls image without any stored credentials)
kubectl get pod test-workload-identity
kubectl logs test-workload-identity
# Expected: Hello from ACR!