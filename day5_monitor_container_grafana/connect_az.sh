# Port-forward Grafana locally (alternative to LoadBalancer)
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80

# Open http://localhost:3000
# Login: admin / (password from above)
# Add data source: Configuration → Data Sources → Add → Prometheus
# URL: http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090