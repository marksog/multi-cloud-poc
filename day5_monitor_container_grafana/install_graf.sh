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