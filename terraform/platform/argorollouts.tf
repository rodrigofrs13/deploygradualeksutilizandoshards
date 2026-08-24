# Argo Rollouts — controla o canário DENTRO de cada shard (o CRD `Rollout`
# usado em apps/springboot/templates/rollout.yaml só existe depois que isso
# é instalado).
#
# Mesmo padrão de argocd.tf: um resource "kubernetes_namespace" explícito +
# helm_release SEM "create_namespace = true". Antes os dois criavam o
# namespace "argo-rollouts" ao mesmo tempo (o resource explícito abaixo E o
# "create_namespace = true" do helm_release), o que costuma falhar com
# "namespaces \"argo-rollouts\" already exists" quando os dois tentam criar
# o mesmo objeto — provavelmente foi isso que travou o apply antes.
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

  # Evita ficar com state "sujo" se a instalação falhar (mesma proteção já
  # usada em argocd.tf).
  cleanup_on_fail = true

  depends_on = [
    kubernetes_namespace.rollouts
  ]
}
