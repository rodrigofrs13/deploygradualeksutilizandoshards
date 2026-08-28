# Hostnames dos NLBs internet-facing do ArgoCD/Argo Workflows (criados por este Terraform via helm_release). Os NLBs da app (springboot-stable,
# criados pelo ArgoCD/ApplicationSet, fora do grafo deste Terraform) NÃO entram aqui de propósito — ver README, "Expondo as apps das shards via
# LoadBalancer" para como pegar o hostname deles. try(...) porque o NLB é provisionado de forma assíncrona: logo após o apply pode vir "".

data "kubernetes_service_v1" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  depends_on = [helm_release.argocd]
}

data "kubernetes_service_v1" "argo_workflows_server" {
  metadata {
    name      = "argo-workflows-server"
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }

  depends_on = [helm_release.argo_workflows]
}

output "argocd_nlb_hostname" {
  description = "Hostname do NLB do ArgoCD. Acesse em https://<hostname> (login: admin / senha inicial via scripts/02-get-argocd-lb-address-and-password.sh). Vazio (\"\") se o NLB ainda não terminou de provisionar."
  value       = try(data.kubernetes_service_v1.argocd_server.status[0].load_balancer[0].ingress[0].hostname, "")
}

output "argo_workflows_nlb_hostname" {
  description = "Hostname do NLB do Argo Workflows. Acesse em https://<hostname>:2746 (porta 2746 é obrigatória, não é 80/443 — veja README). Vazio (\"\") se o NLB ainda não terminou de provisionar."
  value       = try(data.kubernetes_service_v1.argo_workflows_server.status[0].load_balancer[0].ingress[0].hostname, "")
}
