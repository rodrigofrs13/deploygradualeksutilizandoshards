env                         = "dev"
aws_region                  = "us-east-1"
cluster_name                = "eks-automode-dev"

# Precisam bater com terraform/infra/environment/dev/terraform.tfvars —
# usados aqui pelo NodePool (locals.tf/nodepools.tf). Os dois arquivos são
# cópias independentes agora (cada camada tem seu próprio environment/dev/),
# então se mudar um valor, replique no outro.
shard_instance_types = ["m5.large", "m5a.large"]
shard_max_nodes      = 3

# ArgoCD / GitHub — variáveis não sensíveis. O token (github_token) NÃO vai
# aqui: use environment/dev/secrets.tfvars (veja secrets.tfvars.example),
# que fica fora do Git.
argocd_url           = "https://localhost:8080" # troque pela URL real quando tiver Ingress
github_repo_url      = "https://github.com/rodrigofrs13/deploygradualeksutilizandoshards"
argocd_project_name  = "eks-shards"
argocd_apps_path     = "apps/springboot"


node_role_name = "eks-automode-dev-node-role"

# Precisa bater com terraform/infra/environment/dev/terraform.tfvars — usado
# pelo Argo Workflow (argoworkflows-irsa.tf/argoworkflows-template.tf) para
# montar a URL de destino do push no ECR e restringir a policy IAM do IRSA.
ecr_repository_name         = "eks-automode-app-dev"

# github_username/github_token (Personal Access Token, escopo "repo") NÃO
# vão aqui — são consumidos pelo Argo Workflow para dar git push da
# atualização de apps/springboot/values.yaml. Defina-os em
# environment/dev/secrets.tfvars (gitignorado — veja secrets.tfvars.example)
# e passe esse arquivo também com -var-file no apply desta camada.