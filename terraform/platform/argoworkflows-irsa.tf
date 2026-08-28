# IRSA + RBAC para os pods do Argo Workflow (build+push no ECR, gate de promoção shard-1 -> shard-2). 
# Git" e "Promoção shard-1 -> shard-2".
data "tls_certificate" "eks_oidc" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}

data "aws_caller_identity" "current" {}

locals {
  eks_oidc_issuer_hostpath = replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  argo_workflows_namespace = "argo-workflows"
  argo_workflow_sa_name    = "argo-workflow-ecr-push"
  ecr_repository_arn       = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.ecr_repository_name}"
  ecr_repository_url       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/${var.ecr_repository_name}"
}

# Restringe a role à ServiceAccount específica do Argo Workflow (via "sub" do token IRSA).
data "aws_iam_policy_document" "argo_workflow_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer_hostpath}:sub"
      values   = ["system:serviceaccount:${local.argo_workflows_namespace}:${local.argo_workflow_sa_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.eks_oidc_issuer_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "argo_workflow_ecr_push" {
  name               = "${var.cluster_name}-argo-workflow-ecr-push"
  assume_role_policy = data.aws_iam_policy_document.argo_workflow_assume_role.json
}

data "aws_iam_policy_document" "argo_workflow_ecr_push" {
  # GetAuthorizationToken só existe como ação de conta inteira (sem Resource específico).
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [local.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "argo_workflow_ecr_push" {
  name   = "ecr-push"
  role   = aws_iam_role.argo_workflow_ecr_push.id
  policy = data.aws_iam_policy_document.argo_workflow_ecr_push.json
}

# Leitura do alarme do desafio extra (cloudwatch-alarm.tf), restrita ao ARN dele.
data "aws_iam_policy_document" "argo_workflow_cloudwatch_read" {
  statement {
    sid       = "CloudWatchAlarmRead"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = [aws_cloudwatch_metric_alarm.springboot_shard1_health.arn]
  }
}

resource "aws_iam_role_policy" "argo_workflow_cloudwatch_read" {
  name   = "cloudwatch-alarm-read"
  role   = aws_iam_role.argo_workflow_ecr_push.id
  policy = data.aws_iam_policy_document.argo_workflow_cloudwatch_read.json
}

# ServiceAccount usada pelo WorkflowTemplate (spec.serviceAccountName, argoworkflows-template.tf) — anotação injeta as credenciais IRSA.
resource "kubernetes_service_account" "argo_workflow_ecr_push" {
  metadata {
    name      = local.argo_workflow_sa_name
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.argo_workflow_ecr_push.arn
    }
  }

  depends_on = [kubernetes_namespace.argo_workflows]
}

# RBAC mínimo exigido pelo Argo Workflows >= v3.4 para qualquer ServiceAccount custom (create/patch em workflowtaskresults).
resource "kubernetes_role" "argo_workflow_executor" {
  metadata {
    name      = "argo-workflow-executor"
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflowtaskresults"]
    verbs      = ["create", "patch"]
  }

  depends_on = [kubernetes_namespace.argo_workflows]
}

resource "kubernetes_role_binding" "argo_workflow_executor" {
  metadata {
    name      = "argo-workflow-executor"
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.argo_workflow_executor.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argo_workflow_ecr_push.metadata[0].name
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }
}

# ClusterRole (não namespaced) porque os namespaces shard-1/shard-2 só existem após o 1º sync do ArgoCD — ver README, "Promoção shard-1 -> shard-2".
resource "kubernetes_cluster_role" "argo_workflow_rollouts_reader" {
  metadata {
    name = "${var.cluster_name}-argo-workflow-rollouts-reader"
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts"]
    verbs      = ["get", "list", "watch"]
  }

  # rollouts/status é subresource com RBAC próprio — exigido pelo abort (rollback-shard1).
  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts/status"]
    verbs      = ["get", "patch", "update"]
  }
}

resource "kubernetes_cluster_role_binding" "argo_workflow_rollouts_reader" {
  metadata {
    name = "${var.cluster_name}-argo-workflow-rollouts-reader"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.argo_workflow_rollouts_reader.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argo_workflow_ecr_push.metadata[0].name
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }
}

# Patch na Application da shard-2 (sync-shard2, argoworkflows-template.tf) — namespace argocd já existe desde o início, sem problema de ordering.
resource "kubernetes_role" "argo_workflow_argocd_sync" {
  metadata {
    name      = "argo-workflow-argocd-sync"
    namespace = "argocd"
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["applications"]
    verbs      = ["get", "patch"]
  }

  depends_on = [helm_release.argocd]
}

resource "kubernetes_role_binding" "argo_workflow_argocd_sync" {
  metadata {
    name      = "argo-workflow-argocd-sync"
    namespace = "argocd"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.argo_workflow_argocd_sync.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argo_workflow_ecr_push.metadata[0].name
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }

  depends_on = [helm_release.argocd]
}

# Credenciais Git (usuário + PAT) usadas pelo passo update-values pra dar git push. Nunca em tfvars versionado — ver README, "Variáveis por ambiente".
resource "kubernetes_secret" "git_push_credentials" {
  metadata {
    name      = "git-push-credentials"
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }

  type = "Opaque"

  data = {
    username = var.github_username
    token    = var.github_token
  }

  depends_on = [kubernetes_namespace.argo_workflows]
}
