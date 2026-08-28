# Motor do Argo Workflows — build+push da imagem via Kaniko e atualização de apps/springboot/values.yaml no Git. Ver README, "CI: Argo Workflows".
resource "kubernetes_namespace" "argo_workflows" {
  metadata {
    name = "argo-workflows"
  }

  depends_on = [helm_release.argocd]
}

resource "helm_release" "argo_workflows" {
  name       = "argo-workflows"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-workflows"
  namespace  = kubernetes_namespace.argo_workflows.metadata[0].name

  wait    = true
  timeout = 900

  cleanup_on_fail = true

  # Values em ./environment/dev/argo-workflows.yaml — ver README, "Expondo o Argo Workflows via LoadBalancer".
  values = [file("./environment/dev/argo-workflows.yaml")]

  depends_on = [kubernetes_namespace.argo_workflows]
}
