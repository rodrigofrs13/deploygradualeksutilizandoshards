# Só o provider aws é usado nesta camada. Os providers kubernetes/helm/kubectl
# (que autenticavam no cluster via aws_eks_cluster.this + aws_eks_cluster_auth)
# foram movidos para terraform/platform/providers.tf, junto com os resources
# que de fato os utilizam (NodePools, NodeClasses, ArgoCD, Argo Rollouts).
provider "aws" {
  region = var.aws_region
}
