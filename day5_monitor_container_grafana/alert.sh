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