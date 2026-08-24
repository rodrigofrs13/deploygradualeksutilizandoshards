# IRSA (IAM Roles for Service Accounts) para os pods do Argo Workflow que
# fazem o build+push da imagem no ECR (argoworkflows-template.tf).
#
# Diferente do OIDC do GitHub Actions (removido — a integração de CI passou
# a ser o próprio Argo Workflow rodando dentro do cluster), aqui o
# "provedor de identidade" confiado pela IAM é o OIDC issuer NATIVO do
# cluster EKS: todo cluster EKS expõe um endpoint OIDC próprio
# (data.aws_eks_cluster.this.identity[0].oidc[0].issuer), mas a AWS só
# aceita tokens desse issuer depois que ele é registrado explicitamente
# como um IAM OIDC Identity Provider — é o que aws_iam_openid_connect_provider
# faz abaixo. A partir daí, qualquer pod rodando com a ServiceAccount
# anotada (kubernetes_service_account.argo_workflow_ecr_push) recebe um
# token JWT assinado por esse issuer, que a role troca por credenciais
# temporárias via sts:AssumeRoleWithWebIdentity — sem nenhuma access key
# estática armazenada no cluster.
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

data "aws_iam_policy_document" "argo_workflow_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    # Restringe a role a ser assumida SÓ pela ServiceAccount específica do
    # Argo Workflow (não qualquer pod do cluster) — o "sub" de um token
    # IRSA tem o formato system:serviceaccount:<namespace>:<service-account>.
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
  # ecr:GetAuthorizationToken só existe como ação de conta inteira (não
  # aceita Resource específico) — é o único statement com resources = ["*"].
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

# ServiceAccount usada pelo WorkflowTemplate (spec.serviceAccountName em
# argoworkflows-template.tf) — o annotation abaixo é o que o webhook nativo
# do EKS usa para injetar AWS_ROLE_ARN/AWS_WEB_IDENTITY_TOKEN_FILE nos pods,
# permitindo que o Kaniko (que usa a AWS SDK por baixo) autentique no ECR
# sem nenhuma credencial explícita — veja o comentário em
# argoworkflows-template.tf sobre o passo kaniko-build-push.
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

# Credenciais Git (usuário + Personal Access Token) usadas pelo ÚLTIMO passo
# do WorkflowTemplate para dar "git push" da atualização de
# apps/springboot/values.yaml de volta no repositório — é esse push que faz
# o ArgoCD (syncPolicy.automated só na shard-1) pegar a nova imagem.
# var.github_token NUNCA deve vir de um tfvars versionado (veja variables.tf).
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
