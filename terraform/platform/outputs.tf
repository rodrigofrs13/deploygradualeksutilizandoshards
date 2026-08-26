# Hostnames dos NLBs internet-facing criados neste projeto. Só o ArgoCD e
# o Argo Workflows entram aqui — os dois são Services criados diretamente
# por este Terraform (via helm_release), então um data source consegue
# lê-los de forma confiável assim que o apply chega neles.
#
# Os NLBs da app (springboot-stable em shard-1/shard-2,
# apps/springboot/templates/service-stable.yaml) NÃO entram aqui de
# propósito: esses Services são criados pelo ArgoCD (via ApplicationSet,
# argocd-applicationset.tf), fora do grafo de dependências deste
# Terraform — nada garante que já existam no momento do apply
# (principalmente shard-2, que só sincroniza depois de aprovação manual).
# Um data source apontando pra um Service que ainda não existe FALHA o
# apply inteiro (diferente de um resource opcional) — por isso preferimos
# não arriscar. Pra pegar o hostname deles, use os comandos `kubectl get
# svc springboot-stable -n shard-1`/`-n shard-2` já documentados em
# TESTE-END-TO-END.md, seções 8 e 11.
#
# Os dois outputs abaixo usam try(...) porque o NLB é provisionado de
# forma ASSÍNCRONA pelo controller do EKS Auto Mode: logo depois do apply,
# antes do hostname existir, o output vem como "" em vez de dar erro —
# rode "terraform refresh" (ou outro apply) alguns minutos depois se
# precisar do valor.

data "kubernetes_service_v1" "argocd_server" {
  metadata {
    # ATENÇÃO: nome assumido, não 100% confirmado. O Helm release se chama
    # "argocd" (argocd.tf) mas o chart oficial (argo-cd, do repo
    # argoproj/argo-helm) pode gerar um nome de Service diferente
    # dependendo de como o próprio chart calcula seu "fullname" — o script
    # scripts/02-get-argocd-lb-address-and-password.sh já assume
    # "argocd-server" também, mas confirme com
    # `kubectl get svc -n argocd` antes de confiar neste output; se vier
    # diferente, ajuste o nome abaixo (ou troque por uma variável, se
    # preferir não editar código toda vez).
    name      = "argocd-server"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  depends_on = [helm_release.argocd]
}

data "kubernetes_service_v1" "argo_workflows_server" {
  metadata {
    # Nome confirmado via "kubectl describe svc -n argo-workflows" real.
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
