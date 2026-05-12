kubectl delete pod test-keyvault
kubectl delete serviceaccount csi-sa
kubectl delete secretproviderclass azure-kv-secrets
terraform destroy -auto-approve