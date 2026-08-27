env                         = "dev"
aws_region                  = "us-east-1"
cluster_name                = "eks-automode-dev"
kubernetes_version          = "1.35"
ecr_repository_name         = "eks-automode-app-dev"
shard_instance_types        = ["m5.large", "m5a.large"]
shard_max_nodes             = 3
cluster_log_retention_days  = 1


