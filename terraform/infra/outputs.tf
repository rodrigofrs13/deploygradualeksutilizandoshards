output "cluster_name" {
  description = "Nome do cluster EKS"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint da API do cluster EKS"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Certificado CA do cluster (base64), usado no kubeconfig"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_arn" {
  description = "ARN do cluster EKS"
  value       = aws_eks_cluster.this.arn
}

output "node_role_arn" {
  description = "ARN da role usada pelos nodes do Auto Mode"
  value       = aws_iam_role.node.arn
}

output "vpc_id" {
  description = "ID da VPC criada"
  value       = module.vpc.vpc_id
}

output "ecr_repository_url" {
  description = "URL do repositório ECR"
  value       = aws_ecr_repository.this.repository_url
}

output "cluster_log_group" {
  description = "Log group do CloudWatch com os logs do control plane do EKS"
  value       = aws_cloudwatch_log_group.cluster.name
}

# output "argocd_load_balancer_hostname" {
#   description = "Hostname do NLB do ArgoCD — assim que fica disponível, o argocd-cm é apontado automaticamente para ele (pode vir vazio nos primeiros minutos após o apply)"
#   value       = try(data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname, null)
# }

output "configure_kubectl" {
  description = "Comando para configurar o kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}
