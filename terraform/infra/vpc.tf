module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway   = true # Cria um NAT Gateway
  single_nat_gateway   = true # Cria um único NAT Gateway compartilhado por todas as AZs
  enable_dns_hostnames = true # Habilita resolução de hostnames DNS dentro da VPC

  # Necessário pro EKS Auto Mode: os NodePools padrão (system/general-purpose) podem lançar nodes nas subnets públicas
  map_public_ip_on_launch = true

  # Tags exigidas pelo EKS para o cluster reconhecer as subnets para o controller de load balancer do Kubernetes 
  # o controller de load balancer do Kubernetes usa pra descobrir automaticamente em quais subnets criar um NLB/ALB
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}
