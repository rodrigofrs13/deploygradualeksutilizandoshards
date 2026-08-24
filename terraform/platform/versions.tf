terraform {
  required_version = ">= 1.4.4"

  required_providers {
    # Necessário só para autenticar (data "aws_eks_cluster"/"aws_eks_cluster_auth")
    # no cluster já criado pela camada infra — nenhum resource aws_* vive aqui,
    # exceto o OIDC provider IAM/roles do IRSA usado pelo Argo Workflow
    # (argoworkflows-irsa.tf) para dar push no ECR.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.16"
    }

    # Usamos o provider kubectl (em vez do kubernetes_manifest nativo) para
    # aplicar NodeClass/NodePool/AppProject/ApplicationSet/WorkflowTemplate
    # como manifests brutos, sem depender de CRDs conhecidas em tempo de "plan".
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }

    # Usado só em argoworkflows-irsa.tf para obter o thumbprint do
    # certificado do OIDC issuer do cluster EKS (aws_iam_openid_connect_provider).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
