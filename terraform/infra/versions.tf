terraform {
  required_version = ">= 1.7.0"

  required_providers {
    # Único provider usado nesta camada — VPC, IAM, EKS (só o resource do
    # cluster, sem workloads), ECR e CloudWatch Log Group. Os providers
    # kubernetes/helm/kubectl vivem em terraform/platform (ver README),
    # porque nenhum resource daqui os utiliza.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}
