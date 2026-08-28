# Camada platform: aws (autenticação + IRSA do Argo Workflow), kubernetes/helm/kubectl (recursos do cluster) e tls (thumbprint do OIDC issuer).
terraform {
  required_version = ">= 1.7.0"

  required_providers {
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

    # kubectl (não kubernetes_manifest) para aplicar CRDs sem depender delas serem conhecidas em "plan".
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
