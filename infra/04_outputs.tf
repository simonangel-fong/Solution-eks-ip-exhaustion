# outputs.tf

output "update_kube_config" {
  value = "aws eks update-kubeconfig --region ca-central-1 --name ${local.project_name}"
}
