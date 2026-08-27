env                         = "dev"
aws_region                  = "us-east-1"
cluster_name                = "eks-automode-dev"
shard_instance_types = ["m5.large", "m5a.large"]
shard_max_nodes      = 3
node_role_name = "eks-automode-dev-node-role"
ecr_repository_name         = "eks-automode-app-dev"

# ArgoCD / GitHub 
argocd_url           = "https://localhost:8080" # troque pela URL real quando tiver Ingress
github_repo_url      = "https://github.com/rodrigofrs13/deploygradualeksutilizandoshards"
argocd_project_name  = "eks-shards"
argocd_apps_path     = "apps/springboot"



