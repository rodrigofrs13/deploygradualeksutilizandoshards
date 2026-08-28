# ---------------------------------------------------------------------------
# Variáveis específicas de ambiente 
# ---------------------------------------------------------------------------
variable "aws_region" {
  description = "Região AWS onde os recursos serão criados"
  type        = string
}

variable "cluster_name" {
  description = "Nome do cluster EKS"
  type        = string
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes do cluster EKS"
  type        = string
}

variable "ecr_repository_name" {
  description = "Nome do repositório ECR"
  type        = string
}

variable "cluster_log_retention_days" {
  description = "Retenção (em dias) dos logs do control plane do EKS no CloudWatch"
  type        = number
}

variable "ecr_repository_url" {
  type    = string
  default = "246732148991.dkr.ecr.us-east-1.amazonaws.com/eks-automode-app-dev"
}

variable "git_revision" {
  type    = string
  default = "main"
}

variable "env" {
  description = "env"
  type        = string
}



# ---------------------------------------------------------------------------
# Variáveis de rede 
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability Zones utilizadas pela VPC"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnets" {
  description = "CIDRs das subnets privadas (onde os nodes do Auto Mode rodam)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnets" {
  description = "CIDRs das subnets públicas (usadas por Load Balancers)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}
