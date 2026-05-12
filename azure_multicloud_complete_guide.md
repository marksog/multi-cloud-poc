# Azure & Multi-Cloud DevOps — 5-Week Project Guide
### Built for Mark Meyof — Senior DevOps/Platform Engineer
---

## One-time setup (do this before Day 1)

### Install tools

```bash
# Azure CLI (Ubuntu)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Azure CLI (Mac)
brew install azure-cli

# Terraform (any OS via tfenv)
git clone https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
tfenv install 1.6.6 && tfenv use 1.6.6

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Login to Azure
az login
az account list --output table
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# Useful extensions
az extension add --name aks-preview
az extension add --name containerapp
```

### Create your GitHub repo structure

```bash
mkdir -p ~/azure-multicloud-lab
cd ~/azure-multicloud-lab
git init
echo "# Azure Multi-Cloud DevOps Lab" > README.md
git add . && git commit -m "initial commit"
# Push to GitHub (create repo first at github.com)
git remote add origin https://github.com/YOUR_USERNAME/azure-multicloud-lab.git
git push -u origin main
```

---

## WEEK 1: Azure Core + AKS Foundations

---

## Day 1: Terraform on Azure — VNet, Subnets, NSGs + Remote State
**Time:** 2–3 hours | **Cost:** ~$0 (no compute)

### The key difference from AWS state management
AWS needs two resources: S3 bucket (state file) + DynamoDB table (lock).
Azure needs ONE resource: a Storage Account blob. Locking is automatic via blob lease.
When Terraform runs, it acquires a lease on the `.tfstate` blob. Any concurrent run gets HTTP 409. No extra config needed.

---

### Step 1: Create remote state storage (do once, reuse all 25 days)

```bash
# Set variables
LOCATION="eastus"
STATE_RG="rg-tfstate"
# Storage account names: 3-24 chars, lowercase letters and numbers only, globally unique
STORAGE_ACCOUNT="stterraform$(date +%s | tail -c 8)"
CONTAINER_NAME="tfstate"

echo "=== Creating remote state resources ==="
echo "Storage account: $STORAGE_ACCOUNT"

# Create resource group for state
az group create \
  --name $STATE_RG \
  --location $LOCATION \
  --output table

# Create storage account
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $STATE_RG \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --output table

# Enable blob versioning (lets you recover previous state files)
az storage account blob-service-properties update \
  --account-name $STORAGE_ACCOUNT \
  --resource-group $STATE_RG \
  --enable-versioning true

# Create the state container
az storage container create \
  --name $CONTAINER_NAME \
  --account-name $STORAGE_ACCOUNT \
  --output table

# SAVE THIS VALUE — you need it in every backend.tf
echo ""
echo "=== SAVE THIS ==="
echo "STORAGE_ACCOUNT=$STORAGE_ACCOUNT"
echo "================="
```

### Step 2: Set up the project directory

```bash
mkdir -p ~/azure-multicloud-lab/day01-networking
cd ~/azure-multicloud-lab/day01-networking
touch versions.tf backend.tf variables.tf main.tf outputs.tf
```

### Step 3: versions.tf

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
  }
}

provider "azurerm" {
  features {}
}
```

### Step 4: backend.tf
Replace `YOUR_STORAGE_ACCOUNT` with the value from Step 1.

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "YOUR_STORAGE_ACCOUNT"
    container_name       = "tfstate"
    key                  = "day01-networking/terraform.tfstate"
  }
}
```

> **Note:** Each project gets a unique `key`. This is like a folder path inside the container.
> You'll change this to `day02-aks/terraform.tfstate`, `day03-acr/terraform.tfstate`, etc.

### Step 5: variables.tf

```hcl
variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "prefix" {
  description = "Resource name prefix — keep short"
  type        = string
  default     = "lab"
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    project     = "azure-multicloud-lab"
    environment = "dev"
    managed_by  = "terraform"
    day         = "01"
  }
}
```

### Step 6: main.tf

```hcl
# Resource group — equivalent to AWS account-level isolation
resource "azurerm_resource_group" "networking" {
  name     = "rg-${var.prefix}-networking"
  location = var.location
  tags     = var.tags
}

# VNet = AWS VPC
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.prefix}-main"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.networking.location
  resource_group_name = azurerm_resource_group.networking.name
  tags                = var.tags
}

# Public subnet (web tier)
resource "azurerm_subnet" "public" {
  name                 = "snet-public"
  resource_group_name  = azurerm_resource_group.networking.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Private subnet (app tier)
resource "azurerm_subnet" "private" {
  name                 = "snet-private"
  resource_group_name  = azurerm_resource_group.networking.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

# Database subnet
resource "azurerm_subnet" "database" {
  name                 = "snet-database"
  resource_group_name  = azurerm_resource_group.networking.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]
}

# NSG for public subnet — equivalent to AWS Security Group (but attached to subnet, not instance)
resource "azurerm_network_security_group" "public" {
  name                = "nsg-${var.prefix}-public"
  location            = azurerm_resource_group.networking.location
  resource_group_name = azurerm_resource_group.networking.name
  tags                = var.tags

  security_rule {
    name                       = "allow-https-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http-inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "private" {
  name                = "nsg-${var.prefix}-private"
  location            = azurerm_resource_group.networking.location
  resource_group_name = azurerm_resource_group.networking.name
  tags                = var.tags

  security_rule {
    name                       = "allow-from-public-subnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "database" {
  name                = "nsg-${var.prefix}-database"
  location            = azurerm_resource_group.networking.location
  resource_group_name = azurerm_resource_group.networking.name
  tags                = var.tags

  security_rule {
    name                       = "allow-postgres-from-private"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "10.0.2.0/24"
    destination_address_prefix = "*"
  }
}

# Associate NSGs with subnets
resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.public.id
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.private.id
}

resource "azurerm_subnet_network_security_group_association" "database" {
  subnet_id                 = azurerm_subnet.database.id
  network_security_group_id = azurerm_network_security_group.database.id
}
```

### Step 7: outputs.tf

```hcl
output "vnet_id"   { value = azurerm_virtual_network.main.id }
output "vnet_name" { value = azurerm_virtual_network.main.name }
output "resource_group_name" { value = azurerm_resource_group.networking.name }
output "subnet_ids" {
  value = {
    public   = azurerm_subnet.public.id
    private  = azurerm_subnet.private.id
    database = azurerm_subnet.database.id
  }
}
```

### Step 8: Deploy

```bash
# Initialize — downloads azurerm provider AND connects to remote state
terraform init

# Review what will be created (always check before apply)
terraform plan -out=tfplan

# Deploy
terraform apply tfplan

# Confirm state file exists in Azure
az storage blob list \
  --container-name tfstate \
  --account-name $STORAGE_ACCOUNT \
  --output table
# You should see: day01-networking/terraform.tfstate
```

### Step 9: Validate

```bash
# List VNet
az network vnet list --output table

# Show subnets
az network vnet subnet list \
  --resource-group rg-lab-networking \
  --vnet-name vnet-lab-main \
  --output table

# Show NSG rules
az network nsg list --resource-group rg-lab-networking --output table
```

### Step 10: Cleanup

```bash
terraform destroy
# rg-tfstate stays — you reuse it every day
```

### AWS → Azure mapping (memorize for interviews)

| AWS | Azure | Key difference |
|-----|-------|---------------|
| VPC | Virtual Network (VNet) | Azure VNet has no "default" — you create it |
| Subnet | Subnet | Same concept |
| Security Group | NSG (Network Security Group) | NSG attaches to subnet OR NIC, not instance |
| Route Table | UDR (User Defined Route) | Same concept |
| Internet Gateway | Not needed | Azure subnets have internet access by default |
| S3 + DynamoDB | Storage Account blob | Azure uses blob lease for locking — automatic |

### Interview talking points
- "I learned Azure networking from my deep AWS background. The mental model shift was that Azure NSGs attach at the subnet level by default, which is actually cleaner than AWS Security Groups. The state locking was simpler too — no DynamoDB table, just a Storage Account."

---

## Day 2: AKS Cluster with Terraform — Node Pools + Azure CNI
**Time:** 2–3 hours | **Cost:** ~$2–4 (B-series VMs, destroy after)

### Step 1: Create project directory

```bash
mkdir -p ~/azure-multicloud-lab/day02-aks
cd ~/azure-multicloud-lab/day02-aks
```

### Step 2: versions.tf

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```

### Step 3: backend.tf

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "YOUR_STORAGE_ACCOUNT"
    container_name       = "tfstate"
    key                  = "day02-aks/terraform.tfstate"
  }
}
```

### Step 4: variables.tf

```hcl
variable "location"   { type = string; default = "eastus" }
variable "prefix"     { type = string; default = "lab" }
variable "kubernetes_version" { type = string; default = "1.28" }
variable "system_node_count"  { type = number; default = 1 }
variable "user_node_count_min" { type = number; default = 1 }
variable "user_node_count_max" { type = number; default = 3 }
```

### Step 5: main.tf

```hcl
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
    managed                = true
    azure_rbac_enabled     = true
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
```

### Step 6: outputs.tf

```hcl
output "cluster_name"       { value = azurerm_kubernetes_cluster.main.name }
output "resource_group"     { value = azurerm_resource_group.aks.name }
output "kube_config_raw"    { value = azurerm_kubernetes_cluster.main.kube_config_raw; sensitive = true }
output "oidc_issuer_url"    { value = azurerm_kubernetes_cluster.main.oidc_issuer_url }
```

### Step 7: Deploy and connect

```bash
terraform init
terraform apply -auto-approve

# Get kubeconfig
az aks get-credentials \
  --resource-group rg-lab-aks \
  --name aks-lab-main \
  --overwrite-existing

# Verify connection
kubectl get nodes -o wide
# You should see: system pool node (Ready) + user pool node (Ready)

# Check node pools
az aks nodepool list \
  --resource-group rg-lab-aks \
  --cluster-name aks-lab-main \
  --output table

# Compare to EKS — spot the differences
kubectl get pods -n kube-system
# Azure-specific: coredns, azure-cni-networkmonitor, cloud-node-manager
# vs EKS: aws-node (VPC CNI), kube-proxy
```

### Cleanup

```bash
terraform destroy
```

### Interview talking point
- "On EKS I used managed node groups with IRSA. On AKS the equivalent is user assigned managed identity with Workload Identity — the OIDC flow is nearly identical, just different service names. Azure CNI was my choice because it gives pods real VNet IPs, which made the network policy story cleaner."

---

## Day 3: Azure Container Registry (ACR) + AKS Workload Identity
**Time:** 2–3 hours | **Cost:** ~$1

### Concept
AWS: ECR + IRSA (IAM Role for Service Accounts) → pod assumes IAM role via OIDC
Azure: ACR + Workload Identity → pod assumes managed identity via OIDC
The flow is nearly identical. Azure just calls it differently.

### Step 1: Setup

```bash
mkdir -p ~/azure-multicloud-lab/day03-acr-workload-identity
cd ~/azure-multicloud-lab/day03-acr-workload-identity
```

### Step 2: backend.tf

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "YOUR_STORAGE_ACCOUNT"
    container_name       = "tfstate"
    key                  = "day03-acr/terraform.tfstate"
  }
}
```

### Step 3: main.tf

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm"; version = "~> 3.80" }
    azuread = { source = "hashicorp/azuread"; version = "~> 2.46" }
  }
}
provider "azurerm" { features {} }
provider "azuread"  {}

# Get current Azure context
data "azurerm_subscription" "current" {}
data "azurerm_client_config"  "current" {}

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
```

### Step 4: Deploy and test

```bash
terraform init && terraform apply -auto-approve

ACR_NAME=$(terraform output -raw acr_login_server | cut -d'.' -f1)
IDENTITY_CLIENT_ID=$(terraform output -raw managed_identity_client_id)

# Build and push a test image (uses your local Docker)
cat > Dockerfile << 'EOF'
FROM python:3.11-alpine
WORKDIR /app
RUN echo 'print("Hello from ACR!")' > app.py
CMD ["python", "app.py"]
EOF

az acr login --name $ACR_NAME
docker build -t ${ACR_NAME}.azurecr.io/test-app:v1 .
docker push ${ACR_NAME}.azurecr.io/test-app:v1

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
    image: ${ACR_NAME}.azurecr.io/test-app:v1
    imagePullPolicy: Always
EOF
kubectl apply -f test-pod.yaml

# Verify pod runs (pulls image without any stored credentials)
kubectl get pod test-workload-identity
kubectl logs test-workload-identity
# Expected: Hello from ACR!
```

### Cleanup

```bash
kubectl delete pod test-workload-identity
kubectl delete serviceaccount workload-sa
terraform destroy
```

---

## Day 4: Azure Key Vault + Secrets Store CSI Driver on AKS
**Time:** 2–3 hours | **Cost:** ~$0.01

### Step 1: Setup

```bash
mkdir -p ~/azure-multicloud-lab/day04-keyvault
cd ~/azure-multicloud-lab/day04-keyvault
```

### Step 2: main.tf

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm"; version = "~> 3.80" }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "YOUR_STORAGE_ACCOUNT"
    container_name       = "tfstate"
    key                  = "day04-keyvault/terraform.tfstate"
  }
}
provider "azurerm" { features { key_vault { purge_soft_delete_on_destroy = true } } }

data "azurerm_client_config"           "current" {}
data "azurerm_kubernetes_cluster"      "aks"     { name = "aks-lab-main"; resource_group_name = "rg-lab-aks" }
data "azurerm_resource_group"          "aks"     { name = "rg-lab-aks" }

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
  purge_protection_enabled   = false  # Set true in prod

  # Access policies — grant yourself full access
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "List", "Set", "Delete", "Recover", "Purge"]
    key_permissions    = ["Get", "List", "Create", "Delete"]
  }
}

resource "random_string" "suffix" { length = 6; special = false; upper = false }

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
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.csi.principal_id
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

output "key_vault_name"       { value = azurerm_key_vault.main.name }
output "key_vault_uri"        { value = azurerm_key_vault.main.vault_uri }
output "identity_client_id"   { value = azurerm_user_assigned_identity.csi.client_id }
output "tenant_id"            { value = data.azurerm_client_config.current.tenant_id }
```

### Step 3: Deploy and install CSI driver

```bash
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
```

### Step 4: Create SecretProviderClass and test pod

```bash
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
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: app-secrets
          key: DB_PASSWORD
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
```

### Cleanup

```bash
kubectl delete pod test-keyvault
kubectl delete serviceaccount csi-sa
kubectl delete secretproviderclass azure-kv-secrets
terraform destroy
```

---

## Day 5: Azure Monitor + Container Insights + Grafana
**Time:** 2–3 hours | **Cost:** ~$1–2

### Step 1: main.tf

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm"; version = "~> 3.80" }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "YOUR_STORAGE_ACCOUNT"
    container_name       = "tfstate"
    key                  = "day05-monitoring/terraform.tfstate"
  }
}
provider "azurerm" { features {} }

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
  retention_in_days   = 30              # 90 in prod
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

output "log_analytics_workspace_id" { value = azurerm_log_analytics_workspace.main.id }
output "monitor_workspace_id"       { value = azurerm_monitor_workspace.main.id }
```

### Step 2: Deploy and enable Container Insights

```bash
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
```

### Step 3: Install Prometheus + Grafana via Helm

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.service.type=LoadBalancer \
  --set prometheus.prometheusSpec.retention=24h \
  --wait

# Get Grafana LoadBalancer IP
kubectl get svc -n monitoring monitoring-grafana \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Get Grafana admin password
kubectl get secret -n monitoring monitoring-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d && echo
```

### Step 4: Connect Azure Monitor as Prometheus datasource in Grafana

```bash
# Port-forward Grafana locally (alternative to LoadBalancer)
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80

# Open http://localhost:3000
# Login: admin / (password from above)
# Add data source: Configuration → Data Sources → Add → Prometheus
# URL: http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
```

### Step 5: Create an alert rule

```bash
# Create alert for high pod CPU
kubectl apply -f - << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: lab-alerts
  namespace: monitoring
  labels:
    release: monitoring
spec:
  groups:
  - name: lab.rules
    rules:
    - alert: PodCPUHigh
      expr: |
        sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) by (pod, namespace)
        > 0.5
      for: 2m
      labels:
        severity: warning
      annotations:
        summary: "Pod {{ $labels.pod }} high CPU"
        description: "Pod CPU > 50% for 2+ minutes"
    - alert: PodOOMKilled
      expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
      for: 0m
      labels:
        severity: critical
      annotations:
        summary: "Pod {{ $labels.pod }} OOMKilled"
EOF

# Verify alert rule is loaded
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090/alerts
```

### Cleanup

```bash
helm uninstall monitoring -n monitoring
az aks disable-addons --addons monitoring --name aks-lab-main --resource-group rg-lab-aks
terraform destroy
```

### Interview talking point
- "I set up a unified observability layer that mirrored what I'd built on EKS with Prometheus and Grafana. The key difference on Azure is Container Insights plus the Log Analytics Workspace for control plane logs — that's the equivalent of CloudWatch Container Insights plus CloudTrail. The Prometheus + Grafana layer is identical across both clouds, which was the foundation for Week 4's multi-cloud federation project."
---

## WEEK 2: AKS Production Patterns

---

## Day 6: NGINX Ingress + cert-manager + Azure DNS
**Time:** 2–3 hours | **Cost:** ~$0.05 (public IP)

### Step 1: Install NGINX Ingress Controller

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.replicaCount=1 \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
  --wait

# Get the public IP assigned to your ingress
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Ingress IP: $INGRESS_IP"
```

### Step 2: Set up Azure DNS

```bash
# Create DNS zone (use a real or fake domain for lab — e.g. lab.yourdomain.com)
# For lab purposes, use nip.io (free wildcard DNS that resolves any IP)
# e.g. anything.10.0.0.1.nip.io resolves to 10.0.0.1

RESOURCE_GROUP="rg-lab-dns"
az group create --name $RESOURCE_GROUP --location eastus

# Create DNS zone (optional if using nip.io)
DOMAIN="lab.example.com"   # Replace with your domain or use nip.io below
az network dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name $DOMAIN

# Create A record pointing to ingress IP
az network dns record-set a add-record \
  --resource-group $RESOURCE_GROUP \
  --zone-name $DOMAIN \
  --record-set-name "*" \
  --ipv4-address $INGRESS_IP

# For lab without real domain, use nip.io — no DNS needed
# app.${INGRESS_IP}.nip.io will resolve to $INGRESS_IP automatically
echo "Lab URL pattern: app.${INGRESS_IP}.nip.io"
```

### Step 3: Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait

# Verify
kubectl get pods -n cert-manager

# Create ClusterIssuer for Let's Encrypt
# For lab: use staging (no rate limits); for prod use letsencrypt-prod
kubectl apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
```

### Step 4: Deploy test app with TLS ingress

```bash
# Deploy a test application
kubectl apply -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-app
  template:
    metadata:
      labels:
        app: hello-app
    spec:
      containers:
      - name: hello
        image: gcr.io/google-samples/hello-app:1.0
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: hello-app
spec:
  selector:
    app: hello-app
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello-app
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    cert-manager.io/cluster-issuer: "letsencrypt-staging"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - hello.${INGRESS_IP}.nip.io
    secretName: hello-app-tls
  rules:
  - host: hello.${INGRESS_IP}.nip.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello-app
            port:
              number: 80
EOF

# Watch certificate being issued
kubectl get certificate -w
# Goes: False → True (usually 1-2 min)

# Test the endpoint
curl -k https://hello.${INGRESS_IP}.nip.io
# -k flag because staging cert isn't trusted — in prod omit -k
```

### Cleanup

```bash
kubectl delete deployment hello-app
kubectl delete service hello-app
kubectl delete ingress hello-app
helm uninstall ingress-nginx -n ingress-nginx
helm uninstall cert-manager -n cert-manager
```

---

## Day 7: HPA + Cluster Autoscaler + KEDA on AKS
**Time:** 2–3 hours | **Cost:** ~$3–5 (extra nodes during scale test)

### Step 1: Set up test workload with HPA

```bash
# Deploy a CPU-intensive test app
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cpu-load-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cpu-load-test
  template:
    metadata:
      labels:
        app: cpu-load-test
    spec:
      containers:
      - name: app
        image: mcr.microsoft.com/dotnet/samples:aspnetapp
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: cpu-load-test
spec:
  selector:
    app: cpu-load-test
  ports:
  - port: 80
    targetPort: 8080
EOF

# Create HPA — scales when CPU exceeds 50%
kubectl apply -f - << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cpu-load-test-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cpu-load-test
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30     # Scale up fast
    scaleDown:
      stabilizationWindowSeconds: 300    # Scale down slow (avoid flapping)
EOF
```

### Step 2: Trigger HPA scale-up

```bash
# Generate CPU load using a busybox loop
kubectl run load-generator \
  --image=busybox:1.35 \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://cpu-load-test.default.svc.cluster.local/; done"

# Watch HPA react (in another terminal)
kubectl get hpa cpu-load-test-hpa -w
# Watch REPLICAS column increase as CPU climbs above 50%

# Check pod count
kubectl get pods -l app=cpu-load-test

# Stop the load
kubectl delete pod load-generator

# Watch HPA scale back down (takes 5 min due to stabilizationWindow)
kubectl get hpa cpu-load-test-hpa -w
```

### Step 3: Trigger Cluster Autoscaler

```bash
# AKS cluster autoscaler was enabled in Day 2 (enable_auto_scaling = true)
# Verify it's enabled
az aks show \
  --name aks-lab-main \
  --resource-group rg-lab-aks \
  --query "agentPoolProfiles[?name=='user'].{min:minCount, max:maxCount, enabled:enableAutoScaling}"

# Exhaust node capacity by creating many replicas
kubectl scale deployment cpu-load-test --replicas=20

# Watch new nodes being provisioned (takes 2-3 min)
kubectl get nodes -w
# You should see a new node appear

# Check CA logs
kubectl get events --field-selector reason=TriggeredScaleUp -n kube-system

# Scale back down
kubectl scale deployment cpu-load-test --replicas=1
# Node scale-down happens after 10 minutes of underutilization (default)
```

### Step 4: Install KEDA and configure scale-to-zero

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --wait

# Create an Azure Storage Queue (KEDA will scale based on queue depth)
STORAGE_ACCOUNT="stlabkeda$(date +%s | tail -c 6)"
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group rg-lab-aks \
  --location eastus \
  --sku Standard_LRS

QUEUE_NAME="job-queue"
az storage queue create \
  --name $QUEUE_NAME \
  --account-name $STORAGE_ACCOUNT

CONN_STRING=$(az storage account show-connection-string \
  --name $STORAGE_ACCOUNT \
  --resource-group rg-lab-aks \
  --output tsv)

# Store connection string as K8s secret
kubectl create secret generic keda-storage \
  --from-literal=connection="$CONN_STRING"

# Create KEDA ScaledObject — scales from 0 when messages arrive
kubectl apply -f - << EOF
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: queue-processor
spec:
  jobTargetRef:
    template:
      spec:
        containers:
        - name: processor
          image: mcr.microsoft.com/azure-cli
          command: ["az", "storage", "message", "get",
                    "--queue-name", "$QUEUE_NAME",
                    "--account-name", "$STORAGE_ACCOUNT",
                    "--num-messages", "1",
                    "--output", "table"]
        restartPolicy: Never
  pollingInterval: 10
  maxReplicaCount: 5
  scalingStrategy:
    strategy: "accurate"
  triggers:
  - type: azure-queue
    metadata:
      queueName: $QUEUE_NAME
      queueLength: "1"
    authenticationRef:
      name: keda-storage-auth
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-storage-auth
spec:
  secretTargetRef:
  - parameter: connection
    name: keda-storage
    key: connection
EOF

# Add messages to queue to trigger scaling
for i in {1..5}; do
  az storage message put \
    --queue-name $QUEUE_NAME \
    --account-name $STORAGE_ACCOUNT \
    --content "Job message $i"
done

# Watch KEDA create jobs
kubectl get jobs -w
# Jobs should appear and run as messages arrive
```

### Cleanup

```bash
kubectl delete deployment cpu-load-test
kubectl delete service cpu-load-test
kubectl delete hpa cpu-load-test-hpa
kubectl delete scaledjob queue-processor
kubectl delete triggerauthentication keda-storage-auth
kubectl delete secret keda-storage
helm uninstall keda -n keda
az storage account delete --name $STORAGE_ACCOUNT --resource-group rg-lab-aks --yes
```

---

## Day 8: ArgoCD on AKS — Multi-Cluster GitOps
**Time:** 3–4 hours | **Cost:** ~$2

This is your **key multi-cloud story**. Walk through it slowly and understand every step.

### Step 1: Install ArgoCD on AKS

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all pods
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=120s

# Access ArgoCD UI (via port-forward for now)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Get initial admin password
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD password: $ARGOCD_PASS"

# Login via CLI
argocd login localhost:8080 \
  --username admin \
  --password $ARGOCD_PASS \
  --insecure
```

### Step 2: Create the GitOps application repo structure

```bash
# In your GitHub repo, create this structure:
mkdir -p ~/azure-multicloud-lab/gitops-apps/hello-app/{base,overlays/{aks,eks}}
cd ~/azure-multicloud-lab/gitops-apps

# Base Kustomize config
cat > hello-app/base/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello-app
  template:
    metadata:
      labels:
        app: hello-app
    spec:
      containers:
      - name: app
        image: gcr.io/google-samples/hello-app:1.0
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
EOF

cat > hello-app/base/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: hello-app
spec:
  selector:
    app: hello-app
  ports:
  - port: 80
    targetPort: 8080
EOF

cat > hello-app/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
EOF

# AKS overlay — patch replicas for Azure
cat > hello-app/overlays/aks/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
- ../../base
patches:
- patch: |-
    - op: replace
      path: /spec/replicas
      value: 2
  target:
    kind: Deployment
    name: hello-app
commonLabels:
  cloud: azure
EOF

# EKS overlay
cat > hello-app/overlays/eks/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
- ../../base
patches:
- patch: |-
    - op: replace
      path: /spec/replicas
      value: 1
  target:
    kind: Deployment
    name: hello-app
commonLabels:
  cloud: aws
EOF

# Commit and push
git add . && git commit -m "add gitops app structure"
git push
```

### Step 3: Create ArgoCD ApplicationSet for multi-cluster deployment

```bash
# Register a second cluster (use minikube or kind locally to simulate EKS)
# For demo: use a second context in same cluster with different namespace
kubectl create namespace eks-sim   # Simulates EKS target

# Create ApplicationSet — deploys to all registered clusters automatically
kubectl apply -f - << EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: hello-app
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - cluster: aks
        namespace: default
        overlay: aks
      - cluster: eks-sim
        namespace: eks-sim
        overlay: eks
  template:
    metadata:
      name: "hello-app-{{cluster}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/YOUR_USERNAME/azure-multicloud-lab
        targetRevision: HEAD
        path: gitops-apps/hello-app/overlays/{{overlay}}
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{namespace}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
EOF

# Watch both applications sync
argocd app list
argocd app sync hello-app-aks
argocd app sync hello-app-eks-sim

# Verify deployments in both namespaces
kubectl get pods -n default -l app=hello-app
kubectl get pods -n eks-sim  -l app=hello-app
# Note: AKS overlay has 2 replicas, EKS overlay has 1
```

### Step 4: Test GitOps self-healing

```bash
# Manually delete a pod — ArgoCD should recreate it
kubectl delete pod -n default -l app=hello-app --wait=false

# Watch ArgoCD detect drift and correct it within 3 minutes
kubectl get pods -n default -l app=hello-app -w
```

---

## Day 9: Azure Policy + OPA Gatekeeper — AKS Security Hardening
**Time:** 2–3 hours | **Cost:** ~$0

### Step 1: Install OPA Gatekeeper

```bash
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper gatekeeper/gatekeeper \
  --namespace gatekeeper-system \
  --create-namespace \
  --wait

kubectl get pods -n gatekeeper-system
```

### Step 2: Create a ConstraintTemplate (defines the policy rule)

```bash
# Constraint 1: Block privileged containers
kubectl apply -f - << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: noprivilegedcontainers
spec:
  crd:
    spec:
      names:
        kind: NoPrivilegedContainers
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package noprivilegedcontainers

      violation[{"msg": msg}] {
        container := input.review.object.spec.containers[_]
        container.securityContext.privileged == true
        msg := sprintf("Privileged containers not allowed: %v", [container.name])
      }

      violation[{"msg": msg}] {
        container := input.review.object.spec.initContainers[_]
        container.securityContext.privileged == true
        msg := sprintf("Privileged init containers not allowed: %v", [container.name])
      }
EOF

# Constraint 2: Require resource limits
kubectl apply -f - << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: requireresourcelimits
spec:
  crd:
    spec:
      names:
        kind: RequireResourceLimits
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package requireresourcelimits

      violation[{"msg": msg}] {
        container := input.review.object.spec.containers[_]
        not container.resources.limits.cpu
        msg := sprintf("Container %v must have CPU limits", [container.name])
      }

      violation[{"msg": msg}] {
        container := input.review.object.spec.containers[_]
        not container.resources.limits.memory
        msg := sprintf("Container %v must have memory limits", [container.name])
      }
EOF

# Constraint 3: Enforce ACR-only images
kubectl apply -f - << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: allowedregistries
spec:
  crd:
    spec:
      names:
        kind: AllowedRegistries
      validation:
        openAPIV3Schema:
          properties:
            registries:
              type: array
              items:
                type: string
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package allowedregistries

      violation[{"msg": msg}] {
        container := input.review.object.spec.containers[_]
        image := container.image
        satisfied := [good | registry := input.parameters.registries[_]; good := startswith(image, registry)]
        not any(satisfied)
        msg := sprintf("Image %v is not from an allowed registry", [image])
      }
EOF
```

### Step 3: Apply constraints (enforce the rules)

```bash
# Enforce: no privileged containers (applies to all namespaces except system)
kubectl apply -f - << 'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: NoPrivilegedContainers
metadata:
  name: no-privileged-containers
spec:
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system", "argocd", "monitoring"]
  enforcementAction: deny
EOF

# Enforce: resource limits required
kubectl apply -f - << 'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: RequireResourceLimits
metadata:
  name: require-resource-limits
spec:
  match:
    kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    excludedNamespaces: ["kube-system", "gatekeeper-system"]
  enforcementAction: deny
EOF
```

### Step 4: Test enforcement

```bash
# This should FAIL — privileged container
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-privileged
spec:
  containers:
  - name: app
    image: nginx
    securityContext:
      privileged: true
    resources:
      limits:
        cpu: "100m"
        memory: "128Mi"
EOF
# Expected: Error: admission webhook "validation.gatekeeper.sh" denied the request
# Privileged containers not allowed: app

# This should FAIL — no resource limits
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-no-limits
spec:
  containers:
  - name: app
    image: nginx
EOF
# Expected: Error: Container app must have CPU limits

# This should SUCCEED — compliant pod
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-compliant
spec:
  containers:
  - name: app
    image: nginx
    securityContext:
      privileged: false
      runAsNonRoot: true
      runAsUser: 1000
    resources:
      requests:
        cpu: "50m"
        memory: "64Mi"
      limits:
        cpu: "100m"
        memory: "128Mi"
EOF
kubectl get pod test-compliant
```

### Cleanup

```bash
kubectl delete pod test-compliant
kubectl delete noprivilegedcontainers no-privileged-containers
kubectl delete requireresourcelimits require-resource-limits
helm uninstall gatekeeper -n gatekeeper-system
```

---

## Day 10: Private AKS Cluster + Private Endpoints
**Time:** 3–4 hours | **Cost:** ~$1–2

### Step 1: main.tf (private cluster)

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm"; version = "~> 3.80" }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "YOUR_STORAGE_ACCOUNT"
    container_name       = "tfstate"
    key                  = "day10-private-aks/terraform.tfstate"
  }
}
provider "azurerm" { features {} }

resource "azurerm_resource_group" "private" {
  name     = "rg-lab-private-aks"
  location = "eastus"
}

resource "azurerm_virtual_network" "private" {
  name                = "vnet-lab-private"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.private.location
  resource_group_name = azurerm_resource_group.private.name
}

resource "azurerm_subnet" "aks_nodes" {
  name                 = "snet-aks-nodes"
  resource_group_name  = azurerm_resource_group.private.name
  virtual_network_name = azurerm_virtual_network.private.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.private.name
  virtual_network_name = azurerm_virtual_network.private.name
  address_prefixes     = ["10.10.2.0/24"]
  # Disable network policies for private endpoints
  private_endpoint_network_policies_enabled = false
}

resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-lab-private-aks"
  resource_group_name = azurerm_resource_group.private.name
  location            = azurerm_resource_group.private.location
}

# PRIVATE AKS cluster — API server has no public IP
resource "azurerm_kubernetes_cluster" "private" {
  name                    = "aks-lab-private"
  location                = azurerm_resource_group.private.location
  resource_group_name     = azurerm_resource_group.private.name
  dns_prefix              = "lab-private"
  private_cluster_enabled = true     # KEY SETTING — no public API server

  default_node_pool {
    name           = "system"
    node_count     = 1
    vm_size        = "Standard_B2s"
    vnet_subnet_id = azurerm_subnet.aks_nodes.id
    only_critical_addons_enabled = true
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    load_balancer_sku = "standard"
    service_cidr      = "10.10.3.0/24"
    dns_service_ip    = "10.10.3.10"
    # Use internal load balancer — no public IPs for services
    outbound_type     = "userDefinedRouting"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }
}

# Private DNS zone for the cluster (auto-created but we link it to our VNet)
resource "azurerm_private_dns_zone_virtual_network_link" "aks" {
  name                  = "aks-dns-link"
  resource_group_name   = "MC_rg-lab-private-aks_aks-lab-private_eastus"
  private_dns_zone_name = azurerm_kubernetes_cluster.private.private_fqdn
  virtual_network_id    = azurerm_virtual_network.private.id

  depends_on = [azurerm_kubernetes_cluster.private]
}
```

### Step 2: Verify private access

```bash
terraform init && terraform apply -auto-approve

# Private cluster — you can only connect from within the VNet
# Use AKS run-command to exec commands without kubectl access from outside
az aks command invoke \
  --resource-group rg-lab-private-aks \
  --name aks-lab-private \
  --command "kubectl get nodes"

# Verify there's no public endpoint
az aks show \
  --resource-group rg-lab-private-aks \
  --name aks-lab-private \
  --query "fqdn,privateFqdn" \
  --output table
# fqdn should be null, privateFqdn should have value
```

### Cleanup

```bash
terraform destroy
```

### Interview talking point
- "For our most sensitive workloads at Morgan Stanley, we ran private EKS clusters. I replicated this pattern exactly on AKS — private API server, internal load balancers, Private Endpoints for ACR and Key Vault so no traffic left the VNet. The AKS private cluster configuration is actually simpler than EKS — it's a single boolean flag, and Azure handles the private DNS zone automatically."
---

## WEEK 3: Azure DevOps + CI/CD Pipelines

---

## Day 11: Azure DevOps Multi-Stage CI Pipeline
**Time:** 2–3 hours | **Cost:** ~$0

### Step 1: Create Azure DevOps organization

1. Go to https://dev.azure.com → Sign in with your Azure account
2. Create Organization: `lab-devops-mark`
3. Create Project: `azure-lab`
4. Go to Project Settings → Pipelines → Service connections → New → Azure Resource Manager
5. Choose "Workload Identity Federation (automatic)" — this is the preferred method
6. Name it `azure-subscription`

### Step 2: Create pipeline YAML

Create this file at `.azure/ci-pipeline.yml` in your GitHub repo:

```yaml
# .azure/ci-pipeline.yml
trigger:
  branches:
    include:
    - main
  paths:
    include:
    - gitops-apps/**
    - Dockerfile

variables:
  dockerRegistryServiceConnection: 'acr-service-connection'
  imageRepository: 'hello-app'
  containerRegistry: 'YOUR_ACR_NAME.azurecr.io'
  dockerfilePath: '$(Build.SourcesDirectory)/Dockerfile'
  tag: '$(Build.BuildId)'

stages:
# ────────────────────────────────────────────────
- stage: Lint
  displayName: 'Lint and validate'
  jobs:
  - job: Lint
    pool:
      vmImage: 'ubuntu-latest'
    steps:
    - task: UsePythonVersion@0
      inputs:
        versionSpec: '3.11'

    - script: |
        pip install flake8 bandit
        flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics || true
        bandit -r . -ll --exit-zero
      displayName: 'Python linting and security scan'

    - script: |
        # Validate Kubernetes manifests
        curl -sL https://github.com/instrumenta/kubeval/releases/latest/download/kubeval-linux-amd64.tar.gz | tar xz
        find . -name "*.yaml" -path "*/gitops-apps/*" | xargs ./kubeval || true
      displayName: 'Validate Kubernetes manifests'

# ────────────────────────────────────────────────
- stage: Test
  displayName: 'Unit tests'
  dependsOn: Lint
  jobs:
  - job: UnitTest
    pool:
      vmImage: 'ubuntu-latest'
    steps:
    - task: UsePythonVersion@0
      inputs:
        versionSpec: '3.11'

    - script: |
        pip install pytest pytest-cov
        # Run tests if they exist
        if [ -d "tests" ]; then
          pytest tests/ --cov=. --cov-report=xml
        else
          echo "No tests directory — skipping"
        fi
      displayName: 'Run unit tests'

    - task: PublishTestResults@2
      condition: succeededOrFailed()
      inputs:
        testResultsFormat: 'JUnit'
        testResultsFiles: '**/test-*.xml'

# ────────────────────────────────────────────────
- stage: Build
  displayName: 'Build and push container'
  dependsOn: Test
  jobs:
  - job: BuildPush
    pool:
      vmImage: 'ubuntu-latest'
    steps:
    - task: Docker@2
      displayName: 'Build image'
      inputs:
        command: build
        dockerfile: $(dockerfilePath)
        repository: $(imageRepository)
        tags: |
          $(tag)
          latest

    # Security scan BEFORE pushing
    - task: AzureCLI@2
      displayName: 'Scan image with Trivy'
      inputs:
        azureSubscription: 'azure-subscription'
        scriptType: bash
        scriptLocation: inlineScript
        inlineScript: |
          docker run --rm \
            -v /var/run/docker.sock:/var/run/docker.sock \
            aquasec/trivy:latest image \
            --exit-code 0 \
            --severity HIGH,CRITICAL \
            --format table \
            $(imageRepository):$(tag)

    - task: Docker@2
      displayName: 'Push to ACR'
      inputs:
        command: push
        containerRegistry: $(dockerRegistryServiceConnection)
        repository: $(imageRepository)
        tags: |
          $(tag)
          latest

    - task: PublishBuildArtifacts@1
      inputs:
        pathToPublish: '$(System.DefaultWorkingDirectory)'
        artifactName: 'drop'
```

### Step 3: Create ACR service connection

```bash
# Get ACR details
ACR_NAME=$(az acr list --query "[0].name" -o tsv)
ACR_ID=$(az acr show --name $ACR_NAME --query id -o tsv)

# Create service principal for ACR push
SP=$(az ad sp create-for-rbac \
  --name "sp-devops-acr-push" \
  --role AcrPush \
  --scopes $ACR_ID \
  --output json)

echo "Client ID: $(echo $SP | jq -r .appId)"
echo "Client Secret: $(echo $SP | jq -r .password)"
# Add these to Azure DevOps as a Docker Registry service connection
```

### Step 4: Connect pipeline to GitHub and run

1. In Azure DevOps: Pipelines → New Pipeline → GitHub → Select your repo
2. Choose "Existing Azure Pipelines YAML file"
3. Select `.azure/ci-pipeline.yml`
4. Run the pipeline
5. Watch each stage: Lint → Test → Build → Push

---

## Day 12: Azure DevOps CD — Helm Deploy to AKS + Rollback
**Time:** 2–3 hours | **Cost:** ~$0

Add this to the pipeline from Day 11 (append to `.azure/ci-pipeline.yml`):

```yaml
# Append to pipeline after Build stage

# ────────────────────────────────────────────────
- stage: DeployDev
  displayName: 'Deploy to Dev (AKS)'
  dependsOn: Build
  variables:
    environment: dev
    namespace: dev
  jobs:
  - deployment: DeployAKS
    pool:
      vmImage: 'ubuntu-latest'
    environment: 'aks-dev'     # Creates an environment with deployment history
    strategy:
      runOnce:
        deploy:
          steps:
          - task: AzureCLI@2
            displayName: 'Get AKS credentials'
            inputs:
              azureSubscription: 'azure-subscription'
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                az aks get-credentials \
                  --resource-group rg-lab-aks \
                  --name aks-lab-main \
                  --overwrite-existing
                kubectl create namespace $(namespace) --dry-run=client -o yaml | kubectl apply -f -

          - task: HelmDeploy@0
            displayName: 'Helm upgrade (deploy or update)'
            inputs:
              connectionType: 'Kubernetes Service Connection'
              namespace: $(namespace)
              command: upgrade
              chartType: FilePath
              chartPath: '$(Pipeline.Workspace)/drop/helm/hello-app'
              releaseName: 'hello-app'
              overrideValues: |
                image.tag=$(tag)
                image.repository=$(containerRegistry)/$(imageRepository)
                replicaCount=1
              waitForExecution: true
              arguments: '--install --atomic --timeout 5m'
              # --atomic: auto-rollback if deploy fails
              # --wait: wait for pods to be ready

          - task: AzureCLI@2
            displayName: 'Verify deployment health'
            inputs:
              azureSubscription: 'azure-subscription'
              scriptType: bash
              scriptLocation: inlineScript
              inlineScript: |
                # Check rollout status
                kubectl rollout status deployment/hello-app -n $(namespace) --timeout=3m

                # Run a smoke test
                POD=$(kubectl get pod -n $(namespace) -l app=hello-app -o jsonpath='{.items[0].metadata.name}')
                kubectl exec -n $(namespace) $POD -- wget -q -O- http://localhost:8080 | grep -q "Hello"
                echo "Smoke test passed"

# ────────────────────────────────────────────────
- stage: DeployProd
  displayName: 'Deploy to Prod (AKS) — requires approval'
  dependsOn: DeployDev
  jobs:
  - deployment: DeployProd
    pool:
      vmImage: 'ubuntu-latest'
    environment: 'aks-prod'    # Set up approval gate in Azure DevOps UI
    strategy:
      runOnce:
        deploy:
          steps:
          - task: HelmDeploy@0
            displayName: 'Helm upgrade to prod'
            inputs:
              namespace: prod
              command: upgrade
              chartPath: '$(Pipeline.Workspace)/drop/helm/hello-app'
              releaseName: 'hello-app'
              overrideValues: |
                image.tag=$(tag)
                replicaCount=3
              arguments: '--install --atomic --timeout 10m'
```

### Set up approval gate

1. In Azure DevOps: Environments → `aks-prod` → Approvals and checks
2. Add → Approvals → Add yourself as approver
3. Now prod deployment pauses and waits for your manual approval

### Test rollback

```bash
# Simulate a bad deployment by deploying a broken image tag
helm upgrade hello-app ./helm/hello-app \
  --namespace dev \
  --set image.tag=bad-tag-that-doesnt-exist \
  --atomic \
  --timeout 2m
# --atomic means it automatically rolls back on failure

# Check rollback happened
helm history hello-app -n dev
# You'll see the failed revision with status "superseded" and rollback

# Manual rollback if needed
helm rollback hello-app 1 -n dev
```

---

## Day 13: GitHub Actions → Azure with OIDC (No Stored Secrets)
**Time:** 2 hours | **Cost:** ~$0

### Step 1: Create Azure AD App Registration with Federated Credentials

```bash
# Create app registration
APP_ID=$(az ad app create \
  --display-name "github-actions-oidc" \
  --query appId -o tsv)
echo "App ID: $APP_ID"

# Create service principal
SP_ID=$(az ad sp create --id $APP_ID --query id -o tsv)

# Assign Contributor role on your subscription
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az role assignment create \
  --assignee $APP_ID \
  --role Contributor \
  --scope /subscriptions/$SUBSCRIPTION_ID

# Add AcrPush role
ACR_ID=$(az acr list --query "[0].id" -o tsv)
az role assignment create \
  --assignee $APP_ID \
  --role AcrPush \
  --scope $ACR_ID

# Create federated credential — the OIDC trust
# This says: "trust GitHub Actions on main branch of YOUR repo"
az ad app federated-credential create \
  --id $APP_ID \
  --parameters '{
    "name": "github-main-branch",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:YOUR_GITHUB_USERNAME/azure-multicloud-lab:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# Get tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "=== Add these to GitHub Secrets ==="
echo "AZURE_CLIENT_ID=$APP_ID"
echo "AZURE_TENANT_ID=$TENANT_ID"
echo "AZURE_SUBSCRIPTION_ID=$SUBSCRIPTION_ID"
```

### Step 2: Add GitHub Secrets

1. Go to your GitHub repo → Settings → Secrets and variables → Actions
2. Add three secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`

### Step 3: Create GitHub Actions workflow

Create `.github/workflows/deploy-to-azure.yml`:

```yaml
name: Deploy to Azure AKS

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  id-token: write    # REQUIRED for OIDC
  contents: read

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    # OIDC login — no password, no long-lived credential
    - name: Login to Azure via OIDC
      uses: azure/login@v1
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    - name: Get ACR name
      id: acr
      run: |
        ACR_NAME=$(az acr list --query "[0].name" -o tsv)
        echo "name=$ACR_NAME" >> $GITHUB_OUTPUT
        echo "loginServer=$(az acr show --name $ACR_NAME --query loginServer -o tsv)" >> $GITHUB_OUTPUT

    - name: Login to ACR (uses managed identity from OIDC login)
      run: az acr login --name ${{ steps.acr.outputs.name }}

    - name: Build and push image
      run: |
        IMAGE="${{ steps.acr.outputs.loginServer }}/hello-app:${{ github.sha }}"
        docker build -t $IMAGE .
        docker push $IMAGE

    - name: Get AKS credentials
      run: |
        az aks get-credentials \
          --resource-group rg-lab-aks \
          --name aks-lab-main \
          --overwrite-existing

    - name: Deploy to AKS
      run: |
        IMAGE="${{ steps.acr.outputs.loginServer }}/hello-app:${{ github.sha }}"
        # Update image in deployment
        kubectl set image deployment/hello-app \
          app=$IMAGE \
          --namespace default
        kubectl rollout status deployment/hello-app --timeout=5m

    - name: Logout
      if: always()
      run: az logout
```

### Step 4: Verify — confirm no stored credentials

```bash
# Search your repo for any Azure credentials — should find nothing
grep -r "clientSecret\|password\|AZURE_CLIENT_SECRET" .github/
# Should return empty — that's the point
```

---

## Day 14: Terraform Module Library — AWS + Azure
**Time:** 3–4 hours | **Cost:** ~$0

### Directory structure

```bash
mkdir -p ~/azure-multicloud-lab/terraform-modules/{network,kubernetes,container_registry,secret_store}/{aws,azure}
cd ~/azure-multicloud-lab/terraform-modules
```

### Azure network module (`modules/network/azure/main.tf`)

```hcl
variable "name"           { type = string }
variable "location"       { type = string; default = "eastus" }
variable "address_space"  { type = list(string); default = ["10.0.0.0/16"] }
variable "subnets" {
  type = map(object({ cidr = string }))
  default = {
    public   = { cidr = "10.0.1.0/24" }
    private  = { cidr = "10.0.2.0/24" }
  }
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.name}"
  location = var.location
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name}"
  address_space       = var.address_space
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_subnet" "this" {
  for_each             = var.subnets
  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value.cidr]
}

output "vnet_id"    { value = azurerm_virtual_network.this.id }
output "subnet_ids" { value = { for k, s in azurerm_subnet.this : k => s.id } }
output "resource_group_name" { value = azurerm_resource_group.this.name }
```

### AWS network module (`modules/network/aws/main.tf`)

```hcl
variable "name"          { type = string }
variable "cidr_block"    { type = string; default = "10.0.0.0/16" }
variable "subnets" {
  type = map(object({ cidr = string; az = string; public = bool }))
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = true
  tags = { Name = "vpc-${var.name}" }
}

resource "aws_subnet" "this" {
  for_each          = var.subnets
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  map_public_ip_on_launch = each.value.public
  tags = { Name = "snet-${each.key}" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "igw-${var.name}" }
}

output "vpc_id"     { value = aws_vpc.this.id }
output "subnet_ids" { value = { for k, s in aws_subnet.this : k => s.id } }
```

### Root module that uses both (`main.tf`)

```hcl
# Usage in a consuming module:
module "network_azure" {
  source   = "./modules/network/azure"
  name     = "lab"
  location = "eastus"
  subnets  = {
    public   = { cidr = "10.0.1.0/24" }
    private  = { cidr = "10.0.2.0/24" }
  }
}

module "network_aws" {
  source     = "./modules/network/aws"
  name       = "lab"
  cidr_block = "10.1.0.0/16"
  subnets    = {
    public-a  = { cidr = "10.1.1.0/24"; az = "us-east-1a"; public = true }
    private-a = { cidr = "10.1.2.0/24"; az = "us-east-1a"; public = false }
  }
}
```

---

## Day 15: Azure Functions + Blob Storage — Serverless Pipeline
**Time:** 2 hours | **Cost:** ~$0 (consumption plan is free for lab volume)

### Step 1: Set up Azure Functions

```bash
# Install Azure Functions Core Tools
npm install -g azure-functions-core-tools@4 --unsafe-perm true

# Create function app
mkdir -p ~/azure-multicloud-lab/day15-functions
cd ~/azure-multicloud-lab/day15-functions
func init --python

# Create blob trigger function
func new --name BlobProcessor --template "Azure Blob Storage trigger"
```

### Step 2: Function code (`BlobProcessor/__init__.py`)

```python
import logging
import json
import azure.functions as func
from datetime import datetime

def main(blob: func.InputStream, outputBlob: func.Out[str]):
    """
    Triggered when a file is uploaded to 'input-files' container.
    Processes it and writes result to 'processed-files' container.
    Equivalent to AWS Lambda triggered by S3 PutObject.
    """
    logging.info(f"Processing blob: {blob.name}, size: {blob.length} bytes")

    # Read input
    content = blob.read().decode('utf-8')

    # Process (simple example: count words)
    word_count = len(content.split())

    result = {
        "source_file": blob.name,
        "processed_at": datetime.utcnow().isoformat(),
        "word_count": word_count,
        "status": "processed"
    }

    logging.info(f"Processing complete: {result}")

    # Write to output container
    outputBlob.set(json.dumps(result, indent=2))
```

### Step 3: Function bindings (`BlobProcessor/function.json`)

```json
{
  "scriptFile": "__init__.py",
  "bindings": [
    {
      "name": "blob",
      "type": "blobTrigger",
      "direction": "in",
      "path": "input-files/{name}",
      "connection": "AzureWebJobsStorage"
    },
    {
      "name": "outputBlob",
      "type": "blob",
      "direction": "out",
      "path": "processed-files/{name}-result.json",
      "connection": "AzureWebJobsStorage"
    }
  ]
}
```

### Step 4: Deploy

```bash
# Create storage account and function app
FUNC_STORAGE="stfunclab$(date +%s | tail -c 6)"
az storage account create \
  --name $FUNC_STORAGE \
  --resource-group rg-lab-aks \
  --location eastus \
  --sku Standard_LRS

az functionapp create \
  --resource-group rg-lab-aks \
  --consumption-plan-location eastus \
  --runtime python \
  --runtime-version 3.11 \
  --functions-version 4 \
  --name "func-lab-processor-$(date +%s | tail -c 6)" \
  --storage-account $FUNC_STORAGE \
  --os-type Linux

# Create input/output containers
az storage container create --name input-files  --account-name $FUNC_STORAGE
az storage container create --name processed-files --account-name $FUNC_STORAGE

# Deploy function
func azure functionapp publish func-lab-processor-XXXXX

# Test: upload a file to trigger the function
echo "Hello world this is a test file for the Azure function" > test.txt
az storage blob upload \
  --account-name $FUNC_STORAGE \
  --container-name input-files \
  --name test.txt \
  --file test.txt

# Wait 30 seconds, then check output
sleep 30
az storage blob download \
  --account-name $FUNC_STORAGE \
  --container-name processed-files \
  --name "test.txt-result.json" \
  --file result.json
cat result.json
```

---

## WEEK 4: Multi-Cloud Architecture Projects

---

## Day 16: Unified Prometheus + Grafana — AKS + EKS Federation
**Time:** 3–4 hours | **Cost:** ~$2

### Architecture
Two Prometheus instances (one on AKS, one on EKS) both `remote_write` to a central Victoria Metrics or Grafana Mimir. One Grafana reads from both.

### Step 1: Install Prometheus on AKS (already done in Day 5 — reuse)

```bash
# Ensure monitoring stack is up
helm list -n monitoring
# If not running, reinstall:
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.service.type=LoadBalancer
```

### Step 2: Configure remote_write on AKS Prometheus

```bash
# Add a remote_write target using Prometheus Operator
kubectl apply -f - << 'EOF'
apiVersion: monitoring.coreos.com/v1alpha1
kind: PrometheusAgent
metadata:
  name: remote-write-agent
  namespace: monitoring
spec:
  remoteWrite:
  - url: "http://central-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
    writeRelabelConfigs:
    - sourceLabels: [__name__]
      regex: "kube_.*|container_.*|node_.*"
      action: keep
    # Add cloud label to all metrics
    metricRelabelConfigs:
    - targetLabel: cloud
      replacement: azure
    - targetLabel: cluster
      replacement: aks-lab-main
EOF
```

### Step 3: Deploy central Grafana with multi-source datasource

```bash
# Create a ConfigMap with Grafana datasource config that reads from BOTH clouds
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-multi-cloud-datasources
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
    - name: Prometheus-AKS
      type: prometheus
      url: http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
      jsonData:
        customQueryParameters: 'cloud=azure'
    - name: Prometheus-EKS
      type: prometheus
      url: http://prometheus-server.monitoring.svc.cluster.local:80
      jsonData:
        customQueryParameters: 'cloud=aws'
EOF

# Dashboard query to show CPU across BOTH clouds:
# sum(rate(container_cpu_usage_seconds_total{container!=""}[5m])) by (cluster, cloud)
```

### Step 4: Create multi-cloud dashboard JSON

```bash
# Import this dashboard query in Grafana:
# Panel: "CPU by Cluster and Cloud"
# Query A (AKS):
#   datasource: Prometheus-AKS
#   expr: sum(rate(container_cpu_usage_seconds_total{container!="",cloud="azure"}[5m])) by (pod)
#   legend: AKS - {{pod}}
#
# Query B (EKS — if available):
#   datasource: Prometheus-EKS
#   expr: sum(rate(container_cpu_usage_seconds_total{container!="",cloud="aws"}[5m])) by (pod)
#   legend: EKS - {{pod}}
```

---

## Day 17: Cross-Cloud VPN — Azure VNet ↔ AWS VPC
**Time:** 3–4 hours | **Cost:** ~$5–10 (VPN Gateway: ~$0.04/hour)

### Step 1: Azure VPN Gateway (Terraform)

```hcl
# Create VPN Gateway subnet (must be named GatewaySubnet)
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = "rg-lab-networking"
  virtual_network_name = "vnet-lab-main"
  address_prefixes     = ["10.0.10.0/27"]
}

resource "azurerm_public_ip" "vpn_gw" {
  name                = "pip-vpn-gateway"
  location            = "eastus"
  resource_group_name = "rg-lab-networking"
  allocation_method   = "Static"
  sku                 = "Standard"
}

# VPN Gateway (takes 20-40 minutes to provision)
resource "azurerm_virtual_network_gateway" "main" {
  name                = "vpng-lab-main"
  location            = "eastus"
  resource_group_name = "rg-lab-networking"
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw1"    # Cheapest that supports BGP
  enable_bgp          = true
  active_active       = false

  ip_configuration {
    name                          = "vpn-gw-ipconfig"
    public_ip_address_id          = azurerm_public_ip.vpn_gw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  bgp_settings {
    asn = 65010     # Azure ASN — must differ from AWS ASN
  }
}

output "vpn_gateway_public_ip" { value = azurerm_public_ip.vpn_gw.ip_address }
output "vpn_gateway_bgp_asn"   { value = "65010" }
```

### Step 2: AWS side (Terraform)

```hcl
# Customer Gateway (pointing to Azure VPN Gateway IP)
resource "aws_customer_gateway" "azure" {
  bgp_asn    = 65010     # Must match Azure ASN above
  ip_address = "AZURE_VPN_GATEWAY_PUBLIC_IP"    # From Step 1 output
  type       = "ipsec.1"
  tags = { Name = "cgw-azure" }
}

resource "aws_vpn_gateway" "main" {
  vpc_id  = "YOUR_VPC_ID"
  amazon_side_asn = 65020    # AWS ASN — must differ from Azure ASN
  tags = { Name = "vgw-lab" }
}

# VPN Connection
resource "aws_vpn_connection" "azure" {
  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.azure.id
  type                = "ipsec.1"
  static_routes_only  = false    # Use BGP

  tags = { Name = "vpn-to-azure" }
}

output "tunnel1_address"    { value = aws_vpn_connection.azure.tunnel1_address }
output "tunnel1_psk"        { value = aws_vpn_connection.azure.tunnel1_preshared_key; sensitive = true }
output "tunnel1_cgw_inside_address" { value = aws_vpn_connection.azure.tunnel1_cgw_inside_address }
output "tunnel1_vgw_inside_address" { value = aws_vpn_connection.azure.tunnel1_vgw_inside_address }
```

### Step 3: Complete Azure side with AWS tunnel details

```hcl
# Local network gateway (represents AWS VPC)
resource "azurerm_local_network_gateway" "aws" {
  name                = "lng-aws"
  location            = "eastus"
  resource_group_name = "rg-lab-networking"
  gateway_address     = "AWS_TUNNEL1_ADDRESS"    # From AWS output
  address_space       = ["10.1.0.0/16"]          # AWS VPC CIDR

  bgp_settings {
    asn                 = 65020
    bgp_peering_address = "AWS_TUNNEL1_CGW_INSIDE_ADDRESS"
  }
}

resource "azurerm_virtual_network_gateway_connection" "aws" {
  name                = "conn-azure-to-aws"
  location            = "eastus"
  resource_group_name = "rg-lab-networking"

  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.main.id
  local_network_gateway_id   = azurerm_local_network_gateway.aws.id

  shared_key         = "AWS_TUNNEL1_PRESHARED_KEY"
  enable_bgp         = true
}
```

### Step 4: Verify connectivity

```bash
# Check VPN connection status on Azure
az network vpn-connection show \
  --name conn-azure-to-aws \
  --resource-group rg-lab-networking \
  --query "connectionStatus"
# Expected: Connected

# Check BGP peer routes learned from AWS
az network vnet-gateway list-bgp-peer-status \
  --name vpng-lab-main \
  --resource-group rg-lab-networking

# From an AKS pod, ping an AWS private IP
kubectl run test-vpn --image=busybox --rm -it -- ping AWS_PRIVATE_IP
```

---

## Day 18: Multi-Cloud DR — AKS ↔ EKS Failover
**Time:** 3–4 hours | **Cost:** ~$3

### Architecture
- App runs on AKS (primary) and EKS (standby)
- Azure Traffic Manager checks health of AKS endpoint
- On failure, traffic automatically routes to EKS

### Step 1: Terraform — Azure Traffic Manager

```hcl
resource "azurerm_traffic_manager_profile" "app" {
  name                = "tm-lab-multicloud-app"
  resource_group_name = "rg-lab-aks"

  traffic_routing_method = "Priority"    # Primary/failover

  dns_config {
    relative_name = "lab-multicloud-app"
    ttl           = 30    # Low TTL for faster failover
  }

  monitor_config {
    protocol                     = "HTTPS"
    port                         = 443
    path                         = "/healthz"
    interval_in_seconds          = 10
    timeout_in_seconds           = 5
    tolerated_number_of_failures = 2
    # Fails over in ~30 seconds (interval × failures + timeout)
  }
}

# AKS endpoint (primary — priority 1)
resource "azurerm_traffic_manager_azure_endpoint" "aks" {
  name               = "aks-primary"
  profile_id         = azurerm_traffic_manager_profile.app.id
  target_resource_id = azurerm_public_ip.aks_ingress.id
  priority           = 1
  weight             = 100
}

# EKS endpoint (secondary — priority 2)
resource "azurerm_traffic_manager_external_endpoint" "eks" {
  name       = "eks-secondary"
  profile_id = azurerm_traffic_manager_profile.app.id
  target     = "YOUR_EKS_LOAD_BALANCER_DNS"
  priority   = 2
  weight     = 100
}

output "traffic_manager_fqdn" {
  value = azurerm_traffic_manager_profile.app.fqdn
}
```

### Step 2: Test failover

```bash
TM_FQDN=$(terraform output -raw traffic_manager_fqdn)

# Confirm traffic goes to AKS (primary)
curl https://$TM_FQDN/healthz
# Should respond from AKS

# Simulate AKS failure by scaling deployment to 0
kubectl scale deployment hello-app --replicas=0 -n default

# Wait 30-40 seconds for Traffic Manager to detect failure
sleep 40

# Traffic Manager should now route to EKS
curl https://$TM_FQDN/healthz
# Should now respond from EKS

# Restore AKS
kubectl scale deployment hello-app --replicas=2 -n default
# Traffic Manager automatically fails back after AKS health checks pass
```

---

## Day 19: Azure AD + AKS RBAC — Map to AWS IAM Patterns
**Time:** 2–3 hours | **Cost:** ~$0

### Step 1: Create Azure AD groups

```bash
# Create groups
ADMIN_GROUP=$(az ad group create \
  --display-name "aks-cluster-admins" \
  --mail-nickname "aks-cluster-admins" \
  --query id -o tsv)

DEV_GROUP=$(az ad group create \
  --display-name "aks-developers" \
  --mail-nickname "aks-developers" \
  --query id -o tsv)

OPS_GROUP=$(az ad group create \
  --display-name "aks-ops" \
  --mail-nickname "aks-ops" \
  --query id -o tsv)

echo "Admin Group ID: $ADMIN_GROUP"
echo "Dev Group ID: $DEV_GROUP"
echo "Ops Group ID: $OPS_GROUP"
```

### Step 2: Assign Azure RBAC roles at cluster level

```bash
AKS_ID=$(az aks show \
  --name aks-lab-main \
  --resource-group rg-lab-aks \
  --query id -o tsv)

# Admins get full cluster admin
az role assignment create \
  --assignee $ADMIN_GROUP \
  --role "Azure Kubernetes Service RBAC Cluster Admin" \
  --scope $AKS_ID

# Ops get cluster reader + can exec into pods
az role assignment create \
  --assignee $OPS_GROUP \
  --role "Azure Kubernetes Service RBAC Reader" \
  --scope $AKS_ID

# Developers get namespace-scoped access (set below in K8s RBAC)
```

### Step 3: Kubernetes RBAC for developers (namespace-scoped)

```bash
DEV_GROUP_ID="YOUR_DEV_GROUP_OBJECT_ID"

kubectl apply -f - << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer
  namespace: dev
rules:
- apiGroups: ["", "apps", "batch"]
  resources: ["pods", "deployments", "services", "jobs", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
- apiGroups: [""]
  resources: ["pods/log", "pods/exec"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developer-binding
  namespace: dev
subjects:
- kind: Group
  apiGroup: rbac.authorization.k8s.io
  name: "${DEV_GROUP_ID}"    # Azure AD group object ID
roleRef:
  kind: Role
  name: developer
  apiGroup: rbac.authorization.k8s.io
EOF
```

### AWS → Azure IAM mapping document (add to GitHub repo)

```markdown
# IAM/RBAC Mapping: AWS vs Azure

| Concept                  | AWS                         | Azure                              |
|--------------------------|-----------------------------|------------------------------------|
| Identity                 | IAM User/Role               | Azure AD User/Group                |
| Pod identity             | IRSA (IAM Role for SA)      | Workload Identity (Managed ID)     |
| OIDC provider            | EKS OIDC provider           | AKS OIDC issuer URL                |
| Cluster access control   | aws-auth ConfigMap          | Azure AD + Azure RBAC              |
| Node instance identity   | EC2 Instance Profile        | VM Managed Identity                |
| Policy as code           | IAM Policies (JSON)         | Azure Policy / OPA Gatekeeper      |
| Secrets injection        | Secrets Manager + IRSA      | Key Vault + Workload Identity      |
| Audit logs               | CloudTrail                  | Azure Monitor Activity Log         |
```

---

## Day 20: OpenTelemetry Multi-Cloud Trace Aggregation
**Time:** 3 hours | **Cost:** ~$0

### Step 1: Install OTel Collector on AKS

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

# Values file for OTEL Collector
cat > otel-values.yaml << 'EOF'
mode: daemonset

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
    # Collect Kubernetes events as traces
    k8s_events:
      auth_type: serviceAccount

  processors:
    batch:
      timeout: 5s
    # Add cloud/cluster labels to all telemetry
    resource:
      attributes:
      - key: cloud.provider
        value: azure
        action: upsert
      - key: k8s.cluster.name
        value: aks-lab-main
        action: upsert
    memory_limiter:
      check_interval: 1s
      limit_mib: 200

  exporters:
    # Export to Grafana Tempo (change URL to your Tempo instance)
    otlp/tempo:
      endpoint: "http://tempo.monitoring.svc.cluster.local:4317"
      tls:
        insecure: true
    # Also export to STDOUT for debugging
    logging:
      verbosity: basic

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, resource, batch]
        exporters: [otlp/tempo, logging]
      metrics:
        receivers: [otlp]
        processors: [resource, batch]
        exporters: [logging]
EOF

helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --values otel-values.yaml

kubectl get pods -n monitoring | grep otel
```

### Step 2: Instrument a Python Flask app

```python
# app.py — instrumented with OpenTelemetry
from flask import Flask, jsonify
from opentelemetry import trace
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource
import os

# Configure OTEL
resource = Resource.create({
    "service.name": "hello-service",
    "cloud.provider": os.environ.get("CLOUD_PROVIDER", "azure"),
    "k8s.cluster.name": os.environ.get("CLUSTER_NAME", "unknown"),
})

provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(
    endpoint=os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317"),
    insecure=True
)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)
tracer = trace.get_tracer(__name__)

@app.route("/healthz")
def health():
    return jsonify({"status": "ok", "cloud": os.environ.get("CLOUD_PROVIDER", "azure")})

@app.route("/process")
def process():
    with tracer.start_as_current_span("process-request") as span:
        span.set_attribute("cloud", os.environ.get("CLOUD_PROVIDER", "azure"))
        result = {"processed": True, "cloud": os.environ.get("CLOUD_PROVIDER")}
        return jsonify(result)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

---

## WEEK 5: Capstone Projects

---

## Day 21–22: Full Python Microservice — AKS + EKS via ArgoCD
**Time:** 6–8 hours (over 2 days) | **Cost:** ~$3–5

### Step 1: Create the FastAPI application

```bash
mkdir -p ~/azure-multicloud-lab/microservice-app
cd ~/azure-multicloud-lab/microservice-app

# Project structure
mkdir -p {src,tests,helm/templates,helm/charts}

cat > src/main.py << 'EOF'
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
import os
import uvicorn
import logging

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Multi-Cloud Demo API", version="1.0.0")
FastAPIInstrumentor.instrument_app(app)

class Item(BaseModel):
    name: str
    value: str

items = {}

@app.get("/healthz")
async def health():
    return {
        "status": "healthy",
        "cloud": os.environ.get("CLOUD_PROVIDER", "unknown"),
        "cluster": os.environ.get("CLUSTER_NAME", "unknown"),
        "version": os.environ.get("APP_VERSION", "dev")
    }

@app.get("/items")
async def list_items():
    return {"items": items, "count": len(items)}

@app.post("/items")
async def create_item(item: Item):
    if item.name in items:
        raise HTTPException(status_code=400, detail="Item already exists")
    items[item.name] = item.value
    logger.info(f"Created item: {item.name}")
    return {"status": "created", "name": item.name}

@app.get("/items/{name}")
async def get_item(name: str):
    if name not in items:
        raise HTTPException(status_code=404, detail="Item not found")
    return {"name": name, "value": items[name]}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080)
EOF

cat > requirements.txt << 'EOF'
fastapi==0.104.1
uvicorn==0.24.0
pydantic==2.5.0
opentelemetry-api==1.21.0
opentelemetry-sdk==1.21.0
opentelemetry-instrumentation-fastapi==0.42b0
opentelemetry-exporter-otlp-proto-grpc==1.21.0
EOF

cat > Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/ .
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
  CMD wget -q -O- http://localhost:8080/healthz || exit 1
CMD ["python", "main.py"]
EOF
```

### Step 2: Create Helm chart

```bash
cat > helm/Chart.yaml << 'EOF'
apiVersion: v2
name: multicloud-api
description: Multi-cloud demo FastAPI application
version: 0.1.0
appVersion: "1.0.0"
EOF

cat > helm/values.yaml << 'EOF'
replicaCount: 1
image:
  repository: ""
  tag: "latest"
  pullPolicy: Always

cloudProvider: "unknown"
clusterName: "unknown"
appVersion: "1.0.0"

service:
  type: LoadBalancer
  port: 80
  targetPort: 8080

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
EOF

cat > helm/templates/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    app: {{ .Release.Name }}
    cloud: {{ .Values.cloudProvider }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
        cloud: {{ .Values.cloudProvider }}
    spec:
      containers:
      - name: api
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: 8080
        env:
        - name: CLOUD_PROVIDER
          value: {{ .Values.cloudProvider | quote }}
        - name: CLUSTER_NAME
          value: {{ .Values.clusterName | quote }}
        - name: APP_VERSION
          value: {{ .Values.appVersion | quote }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
EOF

cat > helm/templates/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Release.Name }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: {{ .Values.service.targetPort }}
EOF
```

### Step 3: CI with GitHub Actions (builds for both clouds)

Create `.github/workflows/multicloud-deploy.yml`:

```yaml
name: Multi-Cloud Deploy

on:
  push:
    branches: [main]
    paths: ['microservice-app/**']

permissions:
  id-token: write
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.meta.outputs.version }}

    steps:
    - uses: actions/checkout@v4

    - name: Login to Azure
      uses: azure/login@v1
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    - name: Get image tag
      id: meta
      run: echo "version=${{ github.sha }}" >> $GITHUB_OUTPUT

    - name: Build and push to ACR
      run: |
        ACR=$(az acr list --query "[0].loginServer" -o tsv)
        az acr login --name $(az acr list --query "[0].name" -o tsv)
        docker build -t $ACR/multicloud-api:${{ steps.meta.outputs.version }} \
          ./microservice-app
        docker push $ACR/multicloud-api:${{ steps.meta.outputs.version }}
        echo "IMAGE=$ACR/multicloud-api:${{ steps.meta.outputs.version }}" >> $GITHUB_ENV

  deploy-aks:
    needs: build
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - uses: azure/login@v1
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    - name: Deploy to AKS via Helm
      run: |
        az aks get-credentials --resource-group rg-lab-aks --name aks-lab-main
        ACR=$(az acr list --query "[0].loginServer" -o tsv)
        helm upgrade multicloud-api ./microservice-app/helm \
          --install \
          --namespace default \
          --set image.repository=$ACR/multicloud-api \
          --set image.tag=${{ needs.build.outputs.image_tag }} \
          --set cloudProvider=azure \
          --set clusterName=aks-lab-main \
          --set appVersion=${{ needs.build.outputs.image_tag }} \
          --atomic --timeout 5m

    - name: Smoke test
      run: |
        sleep 30
        IP=$(kubectl get svc multicloud-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        curl -f http://$IP/healthz
        echo "AKS deployment verified"
```

### Step 4: Deploy and verify

```bash
git add . && git commit -m "add multicloud microservice capstone"
git push
# Watch GitHub Actions run

# Verify on AKS
kubectl get pods -l app=multicloud-api
kubectl get svc multicloud-api
AKS_IP=$(kubectl get svc multicloud-api -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$AKS_IP/healthz
# Response: {"status":"healthy","cloud":"azure","cluster":"aks-lab-main","version":"..."}
```

---

## Day 23: Microsoft Defender for Containers + Compliance
**Time:** 2–3 hours | **Cost:** ~$0.02

```bash
# Enable Defender for Containers
az security pricing create \
  --name Containers \
  --tier Standard

# Enable on specific AKS cluster
az aks update \
  --resource-group rg-lab-aks \
  --name aks-lab-main \
  --enable-defender

# Run CIS benchmark assessment
az security assessment list \
  --query "[?contains(name, 'aks') || contains(name, 'kubernetes')]" \
  --output table

# View recommendations
az security recommendation list \
  --query "[?resourceDetails.resourceType=='Microsoft.ContainerService/managedClusters'].[displayName,state]" \
  --output table

# Simulate a threat (Defender test)
kubectl run test-threat \
  --image=docker.io/falcosecurity/event-generator:latest \
  --restart=Never \
  -- run syscall --loop
# This generates syscall events that Defender should detect

# Check alerts (may take 5-10 min to appear)
az security alert list \
  --query "[?resourceIdentifiers[?type=='AzureResource']].[alertDisplayName, severity, status]" \
  --output table

kubectl delete pod test-threat
```

---

## Day 24: AKS Spot Node Pools + Cost Optimization
**Time:** 2–3 hours | **Cost:** ~$0.50 (spot VMs are cheap)

```bash
# Add spot node pool to existing cluster
az aks nodepool add \
  --resource-group rg-lab-aks \
  --cluster-name aks-lab-main \
  --name spot \
  --priority Spot \
  --eviction-policy Delete \
  --spot-max-price -1 \          # -1 = pay market price, never overpay vs on-demand
  --enable-cluster-autoscaler \
  --min-count 0 \                # Scale to zero when no workloads
  --max-count 5 \
  --node-vm-size Standard_B2s \
  --no-wait

# Verify pool
az aks nodepool show \
  --resource-group rg-lab-aks \
  --cluster-name aks-lab-main \
  --name spot \
  --query "[scaleSetPriority, provisioningState, count]"

# Deploy a batch workload that tolerates spot eviction
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: batch-workload
spec:
  replicas: 3
  selector:
    matchLabels:
      app: batch
  template:
    metadata:
      labels:
        app: batch
    spec:
      # Schedule on spot nodes if available, fallback to on-demand
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: kubernetes.azure.com/scalesetpriority
                operator: In
                values:
                - spot
      tolerations:
      - key: "kubernetes.azure.com/scalesetpriority"
        operator: "Equal"
        value: "spot"
        effect: "NoSchedule"
      containers:
      - name: batch
        image: busybox
        command: ["sh", "-c", "while true; do echo working; sleep 10; done"]
        resources:
          requests:
            cpu: "100m"
          limits:
            cpu: "200m"
EOF

# Check which nodes the pods land on
kubectl get pods -l app=batch -o wide

# Set up PodDisruptionBudget to handle spot evictions gracefully
kubectl apply -f - << 'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: batch-pdb
spec:
  minAvailable: 1    # Always keep at least 1 pod running during eviction
  selector:
    matchLabels:
      app: batch
EOF

# Calculate cost savings
echo "On-demand Standard_B2s: ~$0.046/hour"
echo "Spot Standard_B2s: ~$0.010/hour (typical)"
echo "Savings: ~78%"
```

---

## Day 25: GitHub Portfolio + Architecture Decision Records
**Time:** 2 hours | **Cost:** ~$0

### Step 1: Repo cleanup checklist

```bash
cd ~/azure-multicloud-lab

# Ensure no secrets committed
git log --all --full-history -- "**/*.tfvars" | head -5
grep -r "password\|secret\|key\b" --include="*.tf" --include="*.yaml" . | \
  grep -v ".git" | grep -v "secretRef\|secretName\|secret_store\|secretKeyRef"

# Add .gitignore
cat > .gitignore << 'EOF'
*.tfstate
*.tfstate.backup
.terraform/
.terraform.lock.hcl
*.tfvars
*.tfvars.json
.env
.env.*
kubeconfig
**/node_modules/
__pycache__/
*.pyc
.DS_Store
EOF

git add .gitignore && git commit -m "add gitignore"
```

### Step 2: Write Architecture Decision Records (ADRs)

Create `docs/adr/` directory with these three files:

**`docs/adr/001-terraform-over-bicep.md`**

```markdown
# ADR 001: Terraform over Azure Bicep for IaC

**Date:** 2025  
**Status:** Accepted

## Context
This project needs Infrastructure as Code that works across both AWS and Azure.
Two options: Terraform (multi-cloud) vs Azure Bicep (Azure-only).

## Decision
Use Terraform for all infrastructure across both clouds.

## Rationale
- Existing Terraform expertise and module library from AWS work
- Single IaC language for multi-cloud reduces cognitive overhead
- Terraform state management is equivalent (Storage Account vs S3+DynamoDB)
- Azure provider is mature and covers all resources used

## Trade-offs
- Bicep has better native Azure type safety and IDE support
- Bicep templates are simpler for Azure-only scenarios
- Would revisit for Azure-only projects where Bicep's native integration matters

## Consequence
All infrastructure described in this repo uses Terraform. Azure-specific
resources use the azurerm provider. Multi-cloud modules use parallel
implementations behind a common interface.
```

**`docs/adr/002-argocd-over-flux.md`**

```markdown
# ADR 002: ArgoCD over Flux for GitOps

**Date:** 2025  
**Status:** Accepted

## Context
Need a GitOps operator to deploy workloads to both AKS and EKS clusters.
Options: ArgoCD vs Flux v2.

## Decision
Use ArgoCD as the primary GitOps operator.

## Rationale
- Existing ArgoCD experience from AWS EKS environments at Morgan Stanley
- ArgoCD's ApplicationSet controller makes multi-cluster targeting cleaner
- Web UI provides better operational visibility for incident response
- Both clusters managed from a single ArgoCD instance (hub-spoke model)

## Trade-offs
- Flux has better GitOps-native design (no API server, pure controllers)
- Flux uses less memory (no UI server)
- Flux's image automation is more mature for automated image update PRs

## Consequence
ArgoCD manages deployments to both AKS and EKS via ApplicationSet.
Would evaluate Flux for teams that need pure GitOps without UI overhead.
```

**`docs/adr/003-azure-cni-over-kubenet.md`**

```markdown
# ADR 003: Azure CNI over Kubenet for AKS Networking

**Date:** 2025  
**Status:** Accepted

## Context
AKS supports two network plugins: Azure CNI (pods get VNet IPs) and kubenet (pods get overlay IPs with NAT).

## Decision
Use Azure CNI for all AKS clusters.

## Rationale
- Pods get real VNet IPs — directly addressable from other subnets, VPN, or peered VNets
- No double-NAT between pods and external systems
- Required for Private Endpoints to work directly with pods
- Consistent with the AWS VPC CNI approach (EKS default)
- Network Policy with Calico works cleanly with Azure CNI

## Trade-offs
- Requires more IP address space (each pod consumes a VNet IP)
- Must pre-plan subnet sizing carefully (plan for max_nodes × max_pods_per_node)
- kubenet is simpler to set up for basic clusters

## Consequence
All AKS clusters in this project use Azure CNI. Subnet sizing follows the
formula: max_nodes × 30 (default pods per node) + 10 buffer.
For a 10-node cluster: 10 × 30 + 10 = 310 IPs → /23 subnet minimum.
```

### Step 3: Write master README

```markdown
# Azure & Multi-Cloud DevOps Lab

Hands-on infrastructure projects built during active job search (2025).
Demonstrates AWS→Azure knowledge transfer and multi-cloud architecture patterns.

## Skills demonstrated
- **Azure:** AKS, ACR, Key Vault, Azure DevOps, Azure Monitor, Traffic Manager
- **Multi-cloud:** Unified GitOps (ArgoCD), cross-cloud Prometheus/Grafana, VPN connectivity
- **IaC:** Terraform modules with parallel AWS/Azure implementations
- **Security:** Workload Identity, OPA Gatekeeper, Defender for Containers, private clusters
- **CI/CD:** Azure DevOps Pipelines, GitHub Actions OIDC (no stored secrets)

## Project structure
| Directory | Description |
|-----------|-------------|
| `day01-networking/` | Azure VNet, NSG, Terraform remote state |
| `day02-aks/` | AKS cluster with Terraform, Azure CNI, node pools |
| `day03-acr-workload-identity/` | ACR + AKS Workload Identity (IRSA equivalent) |
| `day04-keyvault/` | Key Vault + Secrets Store CSI Driver |
| `day08-argocd/` | Multi-cluster GitOps (AKS + EKS) |
| `day14-terraform-modules/` | Reusable modules for AWS + Azure |
| `microservice-app/` | FastAPI service deployed to both AKS and EKS |
| `docs/adr/` | Architecture Decision Records |

## Key design decisions
See [docs/adr/](docs/adr/) for documented decisions on:
- Terraform over Bicep
- ArgoCD over Flux
- Azure CNI over kubenet

## AWS→Azure mapping
See [docs/aws-azure-mapping.md](docs/aws-azure-mapping.md) for full service equivalents.
```

### Step 4: Pin repos on GitHub profile

1. Go to your GitHub profile → Customize your profile → Repositories
2. Pin: `azure-multicloud-lab`
3. Write profile README at `github.com/YOUR_USERNAME/YOUR_USERNAME/blob/main/README.md`

```markdown
## Mark Meyof — Senior DevOps & Platform Engineer

10+ years across Platform Engineering, Cloud Infrastructure, and Network Engineering.

**Current focus:** Multi-cloud DevOps (AWS + Azure), Kubernetes at scale, GitOps
**Certs:** AWS DevOps Pro · AWS Solutions Architect Pro · CKA · CKS · CCNP
**Tools:** Terraform · AKS · EKS · ArgoCD · Prometheus · Grafana · Python

📌 Pinned: [azure-multicloud-lab](link) — 25 daily projects, AWS→Azure knowledge transfer
```

---

## Quick Reference: AWS → Azure

| AWS | Azure |
|-----|-------|
| VPC | Virtual Network (VNet) |
| Security Group | Network Security Group (NSG) |
| IAM Role | Managed Identity |
| IRSA | Workload Identity |
| EKS | AKS |
| ECR | ACR |
| Secrets Manager | Key Vault (secrets) |
| Parameter Store | Key Vault (keys/configs) |
| S3 + DynamoDB lock | Storage Account blob (auto-lock) |
| CloudWatch | Azure Monitor + Log Analytics |
| CloudTrail | Activity Log |
| Lambda | Azure Functions |
| Route 53 | Azure DNS |
| ALB | Azure Application Gateway |
| NLB | Azure Load Balancer (Standard) |
| CloudFormation | Bicep / ARM Templates |
| CodePipeline | Azure DevOps Pipelines |
| EKS Node Group | AKS Node Pool |
| Karpenter | AKS Cluster Autoscaler / KEDA |
| AWS Config | Azure Policy |
| GuardDuty | Microsoft Defender for Cloud |
| ACM | Azure Key Vault Certificates |
| VPC Peering | VNet Peering |
| Transit Gateway | Azure Virtual WAN / VNet Hub |
| Direct Connect | ExpressRoute |
| Site-to-Site VPN | Azure VPN Gateway |
