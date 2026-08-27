module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Necessário pro EKS Auto Mode: os NodePools padrão (system/general-purpose)
  # podem lançar nodes nas subnets públicas, e o endpoint do cluster aqui é
  # só público (endpointPrivateAccess = false, ver eks.tf). Sem IP público
  # automático, um node lançado na subnet pública tem rota pro Internet
  # Gateway mas nenhum jeito de completar a conexão de volta — e nunca
  # consegue se registrar no cluster (nodeclaim fica preso em
  # Launched=True / Registered=Unknown "Node not registered with cluster"
  # pra sempre, até o grace period expirar e o Karpenter tentar de novo).
  map_public_ip_on_launch = true

  # Tags exigidas pelo EKS para o cluster reconhecer as subnets
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}
