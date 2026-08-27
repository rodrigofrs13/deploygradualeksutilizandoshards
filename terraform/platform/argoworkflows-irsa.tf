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

# Permissão extra pro step check-cloudwatch-alarm (argoworkflows-template.tf,
# desafio extra de promoção automática): só leitura do estado do alarme
# criado em cloudwatch-alarm.tf, restrita ao ARN dele especificamente (não
# "cloudwatch:*" nem "resources = [*]").
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

# RBAC mínimo exigido pelo próprio Argo Workflows para QUALQUER
# ServiceAccount usada como spec.serviceAccountName de um Workflow — sem
# isso, o passo falha com "workflowtaskresults.argoproj.io is forbidden:
# ... cannot create resource workflowtaskresults", porque desde a v3.4 o
# executor (emissary) reporta o resultado de cada passo criando/atualizando
# um objeto WorkflowTaskResult, em vez de dar patch direto no Pod. O chart
# argo-workflows cria esse Role/RoleBinding automaticamente só para a
# ServiceAccount default que ELE gerencia — como usamos uma ServiceAccount
# própria (por causa do IRSA acima), precisamos conceder isso manualmente.
# Referência: https://argo-workflows.readthedocs.io/en/latest/workflow-rbac/
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

# RBAC extra para o gate de aprovação/promoção entre shard-1 e shard-2 (ver
# argoworkflows-template.tf, steps wait-shard1-healthy / rollback-shard1 /
# sync-shard2): a mesma ServiceAccount do pipeline de build precisa (1) ler
# e (agora) abortar o Rollout da shard-1, e (2) dar patch na Application da
# shard-2.

# (1) Leitura + abort do Rollout via CLUSTER ROLE, de propósito — não um
# "kubernetes_role" namespaced. Os namespaces shard-1/shard-2 só existem
# depois do PRIMEIRO sync do ArgoCD (ver README, "Estrutura"/seção 3 do
# TESTE-END-TO-END.md); um Role apontando para um namespace que ainda não
# existe falharia no primeiro "terraform apply" da camada platform. Um
# ClusterRole/ClusterRoleBinding não referencia nenhum namespace
# específico, então não tem esse problema de ordering — o preço é que a
# permissão vale pra qualquer namespace, não só shard-1/shard-2 (aceitável:
# é só o CRD do Argo Rollouts, e o "patch" fica restrito ao subresource
# "status", usado só pelo abort).
resource "kubernetes_cluster_role" "argo_workflow_rollouts_reader" {
  metadata {
    name = "${var.cluster_name}-argo-workflow-rollouts-reader"
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["rollouts"]
    verbs      = ["get", "list", "watch"]
  }

  # Necessário pro step rollback-shard1 (kubectl patch --subresource
  # status): sem esse rule extra, o patch falha com "rollouts/status is
  # forbidden" mesmo já tendo "get" no recurso principal — subresources têm
  # RBAC próprio, independente do recurso "pai".
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

# (2) Patch na Application da shard-2 — Role namespaced normal, sem o
# problema de ordering acima: o namespace "argocd" já existe desde o início
# (argocd.tf), bem antes deste recurso.
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
