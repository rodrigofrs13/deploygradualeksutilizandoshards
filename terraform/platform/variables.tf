# Variáveis da camada platform — mesmo var-file da camada infra (ver README, "Variáveis por ambiente").
variable "aws_region" {
  description = "Região AWS do cluster EKS (usada só para autenticar via data source)"
  type        = string
}

variable "node_role_name" {
  description = <<-EOT
    Override opcional do nome da IAM role dos nodes. Por padrão (null),
    local.node_role_name (locals.tf) deduz o nome a partir de
    var.cluster_name, seguindo o padrão "<cluster_name>-node-role" criado
    por terraform/infra/iam.tf — não precisa mais declarar isso manualmente
    no tfvars. Defina só se um dia esse padrão de nome mudar.
  EOT
  type    = string
  default = null
}

variable "cluster_name" {
  description = "Nome do cluster EKS já criado pela camada infra"
  type        = string
}

variable "shard_instance_types" {
  description = "Tipos de instância EC2 dos NodePools shard-1/shard-2 — precisam ter specs em local.instance_specs (locals.tf). Ver README, \"Isolamento físico das shards\"."
  type        = list(string)
}

variable "shard_max_nodes" {
  description = "Número máximo aproximado de EC2 por nodepool shard (via limits de CPU/memória — ver locals.tf)"
  type        = number
}

# ---------------------------------------------------------------------------
# Integração ArgoCD <-> GitHub
# ---------------------------------------------------------------------------
variable "argocd_url" {
  description = "URL externa do ArgoCD — não consumida por nenhum resource hoje. Ver README, \"Sobre 'Argo CD URL: https://null'\"."
  type        = string
}

variable "github_repo_url" {
  description = "URL HTTPS do repositório GitHub com os manifests dos apps (ex.: https://github.com/org/repo.git)"
  type        = string
}

variable "argocd_project_name" {
  description = "Nome do AppProject do ArgoCD"
  type        = string
  default     = "eks-shards"
}

variable "argocd_apps_path" {
  description = "Caminho, no repositório GitHub, do chart Helm reaproveitado pelas duas shards. Ver README, \"Entre shards\"."
  type        = string
  default     = "apps/springboot"
}

# ---------------------------------------------------------------------------
# Argo Workflows (build + push da imagem no ECR e atualização do values.yaml)
# ---------------------------------------------------------------------------
variable "ecr_repository_name" {
  description = "Nome do repositório ECR — precisa bater com terraform/infra/environment/dev/terraform.tfvars"
  type        = string
}

variable "github_username" {
  description = "Usuário GitHub dono do PAT usado pelo Argo Workflow para git push. Defina em environment/dev/secrets.tfvars (gitignorado)."
  type        = string
}

variable "github_token" {
  description = "Personal Access Token do GitHub (escopo repo). Nunca em tfvars versionado — use secrets.tfvars ou TF_VAR_github_token."
  type        = string
  sensitive   = true
}
