# Argo Rollouts — controla o canário dentro de cada shard (CRD Rollout usado em apps/springboot/templates/rollout.yaml).
# Cria Namespace 
resource "kubernetes_namespace" "rollouts" {
  metadata {
    name = "argo-rollouts"
  }

  depends_on = [
    helm_release.argocd
  ]
}

resource "helm_release" "argo_rollouts" {
  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  namespace  = kubernetes_namespace.rollouts.metadata[0].name

  wait    = true
  timeout = 900

  cleanup_on_fail = true # Se um helm install falhar no meio do caminho ele deixa pra trás os recursos que já chegou a criar e marca o release como failed. 
  # Da próxima vez que você rodar terraform apply, o Helm tenta fazer upgrade em cima desse release "sujo" e frequentemente trava com erro de conflito.

  depends_on = [
    kubernetes_namespace.rollouts
  ]
}
