# Motor do Argo Workflows — dispara, sob comando manual (`argo submit`, veja
# README), o build+push da imagem Java via Kaniko (sem Docker-in-Docker) e a
# atualização de apps/springboot/values.yaml no Git sempre que algo mudar em
# apps/. Substitui a abordagem de GitHub Actions + OIDC (removida —
# terraform/infra/github-oidc.tf): tudo roda dentro do próprio cluster, sem
# depender de OIDC do GitHub nem de secrets configurados no GitHub.
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

  # Evita ficar com state "sujo" se a instalação falhar (mesma proteção já
  # usada em argocd.tf/argorollouts.tf).
  cleanup_on_fail = true

  # server.extraArgs com --auth-mode=server deixa a UI acessível sem exigir
  # login SSO/client — suficiente para uma Demo local (não use assim em
  # produção). O disparo do build em si continua manual via `argo submit`
  # (ver README) — isso só afeta o acesso à UI/API.
  set {
    name  = "server.extraArgs[0]"
    value = "--auth-mode=server"
  }

  depends_on = [kubernetes_namespace.argo_workflows]
}
