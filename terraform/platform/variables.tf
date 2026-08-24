# ---------------------------------------------------------------------------
# Variáveis da camada platform (NodePools, NodeClasses, ArgoCD, Argo
# Rollouts). Alimentadas pelo MESMO var-file usado pela camada infra
# (../infra/environment/dev/terraform.tfvars) — Terraform apenas emite um
# warning para as chaves desse arquivo que não são declaradas aqui (ex.:
# kubernetes_version, ecr_repository_name), o que é esperado e inofensivo
# quando duas camadas compartilham um var-file. Veja o README.
# ---------------------------------------------------------------------------
variable "aws_region" {
  description = "Região AWS do cluster EKS (usada só para autenticar via data source, o cluster já existe)"
  type        = string
}


variable "node_role_name" {
  description = "node_role_name"
  type        = string
}

variable "cluster_name" {
  description = "Nome do cluster EKS já criado pela camada infra"
  type        = string
}

variable "shard_instance_types" {
  description = <<-EOT
    Tipos de instância EC2 aceitos pelos NodePools shard-1 e shard-2 (todos
    precisam ter specs cadastradas no mapa local.instance_specs em
    locals.tf). Usar mais de um tipo reduz o risco de falha por falta de
    capacidade Spot de um tipo específico. O limite de "máximo N EC2" é
    calculado com base no MAIOR tipo do conjunto (ver locals.tf).
  EOT
  type = list(string)
}

variable "shard_max_nodes" {
  description = "Número máximo de EC2 por nodepool shard (aproximado via limits de CPU/memória)"
  type        = number
}

# ---------------------------------------------------------------------------
# Integração ArgoCD <-> GitHub
# ---------------------------------------------------------------------------
variable "argocd_url" {
  description = <<-EOT
    URL externa do ArgoCD. Atualmente não é consumida por nenhum resource
    (o patch automático do argocd-cm descrito em versões antigas do README
    foi removido) — mantida aqui só para não quebrar o var-file compartilhado.
    Se quiser corrigir a URL exibida pelo ArgoCD, defina "configs.cm.url"
    diretamente em environment/dev/argocd.yaml.
  EOT
  type = string
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
  description = <<-EOT
    Caminho, dentro do repositório GitHub, do chart Helm da aplicação.
    argocd-applicationset.tf define DUAS ApplicationSets (uma por shard,
    veja o arquivo), ambas apontando para este MESMO caminho e
    sobrescrevendo só "shard"/"namespace" via spec.source.helm.parameters.
    Não é mais um glob de diretórios (antes era "apps/*", um app por
    subpasta); hoje é um caminho fixo para um único chart reaproveitado
    pelas duas shards.
  EOT
  type = string
  default = "apps/springboot"
}

# ---------------------------------------------------------------------------
# Argo Workflows (build + push da imagem no ECR e atualização do values.yaml)
# — ver argoworkflows.tf / argoworkflows-irsa.tf / argoworkflows-template.tf
# ---------------------------------------------------------------------------
variable "ecr_repository_name" {
  description = <<-EOT
    Nome do repositório ECR (mesmo valor de terraform/infra/environment/dev/terraform.tfvars
    — precisa bater, já que infra/platform são states independentes). Usado
    pelo Argo Workflow para montar a URL de destino do "docker push" via
    Kaniko (argoworkflows-template.tf) e para restringir a policy IAM do
    IRSA (argoworkflows-irsa.tf) a esse repositório específico.
  EOT
  type = string
}

variable "github_username" {
  description = <<-EOT
    Usuário GitHub dono do Personal Access Token usado pelo Argo Workflow
    para dar "git push" de volta no repositório (atualização de
    apps/springboot/values.yaml após o build). Defina junto com
    github_token em environment/dev/secrets.tfvars (gitignorado — veja
    secrets.tfvars.example), nunca em um tfvars versionado.
  EOT
  type = string
}

variable "github_token" {
  description = <<-EOT
    Personal Access Token do GitHub (escopo "repo", para permitir push) usado
    pelo Argo Workflow. Vai para um Kubernetes Secret (git-push-credentials,
    argoworkflows-irsa.tf) consumido só pelo passo final do WorkflowTemplate.
    NUNCA em um tfvars versionado — use environment/dev/secrets.tfvars
    (gitignorado) ou TF_VAR_github_token.
  EOT
  type      = string
  sensitive = true
}
