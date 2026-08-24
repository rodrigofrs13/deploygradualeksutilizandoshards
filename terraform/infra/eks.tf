resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # Auto Mode requer o modo de autenticação baseado em API
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids = concat(module.vpc.private_subnets, module.vpc.public_subnets)
  }

  # Habilita o EKS Auto Mode: a AWS passa a gerenciar o provisionamento
  # e o ciclo de vida dos nodes automaticamente
  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  # Habilita todos os tipos de log do control plane: api, audit,
  # authenticator, controllerManager e scheduler — todos enviados para o
  # CloudWatch Logs em aws_cloudwatch_log_group.cluster
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  # Com Auto Mode, os add-ons básicos (CoreDNS, kube-proxy, VPC CNI)
  # são geridos pela AWS, então desabilitamos o bootstrap self-managed
  bootstrap_self_managed_addons = false

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy_attachment.cluster_compute_policy,
    aws_iam_role_policy_attachment.cluster_blockstorage_policy,
    aws_iam_role_policy_attachment.cluster_loadbalancing_policy,
    aws_iam_role_policy_attachment.cluster_networking_policy,
    aws_cloudwatch_log_group.cluster,
  ]
}
