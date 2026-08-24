# ---------------------------------------------------------------------------
# Variáveis específicas de ambiente — sem default: precisam vir de um
# arquivo de var-file, ex.: environment/dev/terraform.tfvars
# (terraform plan -var-file=environment/dev/terraform.tfvars)
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

# As variáveis de integração ArgoCD <-> GitHub (argocd_url, github_repo_url,
# argocd_project_name, argocd_apps_path) foram movidas para
# terraform/platform/variables.tf — é lá que o ArgoCD é instalado agora.
# NUNCA coloque github_token em um tf.vars versionado no Git; use um arquivo
# separado, gitignorado (ex.: environment/dev/secrets.tfvars) ou variáveis
# de ambiente TF_VAR_*.

# variable "github_username" {
#   description = "Usuário GitHub associado ao Personal Access Token"
#   type        = string
# }

variable "ecr_repository_url" {
  type    = string
  default = "CHANGE-ME.dkr.ecr.us-east-1.amazonaws.com/springboot-sharded-app"
}

variable "git_revision" {
  type    = string
  default = "main"
}

variable "env" {
  description = "env"
  type        = string
}


# variable "github_token" {
#   description = "Personal Access Token do GitHub usado pelo ArgoCD para acessar o repositório (defina via arquivo de secrets separado ou TF_VAR_github_token, nunca em um tfvars versionado)"
#   type        = string
#   sensitive   = true
# }

# ---------------------------------------------------------------------------
# Variáveis de rede — mantêm default porque raramente mudam entre ambientes
# nesse exemplo simples, mas também podem ser sobrescritas no tf.vars
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
