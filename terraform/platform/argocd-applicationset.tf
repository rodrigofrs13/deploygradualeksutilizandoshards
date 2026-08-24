# Controla o deploy da app nas duas shards: DUAS ApplicationSets do
# ArgoCD (uma por shard), ambas apontando pro mesmo chart Helm
# (var.argocd_apps_path = apps/springboot), com "shard"/"namespace"
# sobrescritos via spec.source.helm.parameters.
#
# Aprovação manual entre shards (requisito do desafio): só
# `argocd_applicationset_shard_1` tem `syncPolicy.automated` — sincroniza
# sozinha assim que o chart mudar no Git. `argocd_applicationset_shard_2`
# NÃO tem `syncPolicy.automated` de propósito, então fica `OutOfSync` até
# alguém rodar `argocd app sync springboot-shard-2` (ou o `kubectl patch`
# equivalente, veja o README) — só depois disso a shard 2 sincroniza e
# começa o seu próprio canário.
#
# Os dois resources são dois `kubectl_manifest` fixos (em vez de um único
# ApplicationSet com list generator de 2 itens) porque o `syncPolicy.automated`
# da shard-1 precisa existir e o da shard-2 precisa estar TOTALMENTE AUSENTE
# — e o `goTemplate` do ArgoCD só substitui valores escalares dentro de uma
# estrutura YAML já válida, não consegue incluir/omitir uma chave YAML
# inteira condicionalmente. Duas Applications estáticas, cada uma com o
# `syncPolicy` certo hardcoded, evitam esse problema por completo.
#
# O canário DENTRO de cada shard é feito pelo Argo Rollouts (recurso
# Rollout em apps/springboot/templates/rollout.yaml, com os passos definidos
# em apps/springboot/values.yaml canary.steps) — precisa do Argo Rollouts
# instalado (argorollouts.tf) para o CRD `Rollout` existir no cluster.

# Shard 1 — sincroniza sozinha assim que o chart mudar no Git.
resource "kubectl_manifest" "argocd_applicationset_shard_1" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: ApplicationSet
    metadata:
      name: springboot-shard-1
      namespace: argocd
    spec:
      generators:
        - list:
            elements:
              - {}
      template:
        metadata:
          name: springboot-shard-1
        spec:
          project: ${var.argocd_project_name}
          source:
            repoURL: ${var.github_repo_url}
            targetRevision: HEAD
            path: ${var.argocd_apps_path}
            helm:
              parameters:
                - name: shard
                  value: shard-1
                - name: namespace
                  value: shard-1
          destination:
            server: https://kubernetes.default.svc
            namespace: shard-1
          syncPolicy:
            automated:
              prune: true
              selfHeal: true
            syncOptions:
              - CreateNamespace=true
  YAML

  depends_on = [
    kubectl_manifest.argocd_project
  ]
}

# Shard 2 — SEM syncPolicy.automated de propósito (aprovação manual entre
# shards, requisito do desafio). Fica OutOfSync até `argocd app sync
# springboot-shard-2` (veja README, seção "Deploy gradual").
resource "kubectl_manifest" "argocd_applicationset_shard_2" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: ApplicationSet
    metadata:
      name: springboot-shard-2
      namespace: argocd
    spec:
      generators:
        - list:
            elements:
              - {}
      template:
        metadata:
          name: springboot-shard-2
        spec:
          project: ${var.argocd_project_name}
          source:
            repoURL: ${var.github_repo_url}
            targetRevision: HEAD
            path: ${var.argocd_apps_path}
            helm:
              parameters:
                - name: shard
                  value: shard-2
                - name: namespace
                  value: shard-2
          destination:
            server: https://kubernetes.default.svc
            namespace: shard-2
          syncPolicy:
            syncOptions:
              - CreateNamespace=true
  YAML

  depends_on = [
    kubectl_manifest.argocd_project
  ]
}
