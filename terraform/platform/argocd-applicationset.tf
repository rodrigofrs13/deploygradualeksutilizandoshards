# Controla o deploy da app nas duas shards: DUAS ApplicationSets do
# ArgoCD (uma por shard), ambas apontando pro mesmo chart Helm
# (var.argocd_apps_path = apps/springboot), com "shard"/"namespace"
# sobrescritos via spec.source.helm.parameters.
#
# ATENÇÃO — decisão deliberada, registrada aqui para não parecer descuido:
# as DUAS shards têm `syncPolicy.automated` (auto-sync), sem aprovação
# manual entre elas. Isso DIVERGE do requisito funcional original do
# desafio ("aprovação manual entre shards via ArgoCD"), que era o
# comportamento anterior desses dois resources (shard-2 sem
# `syncPolicy.automated`, exigindo `argocd app sync springboot-shard-2`).
# A mudança foi um pedido explícito do usuário para tornar o pipeline
# totalmente automático fim a fim; se for entregar isso como parte de uma
# avaliação técnica que pede aprovação manual, reverta removendo o bloco
# `automated` de `argocd_applicationset_shard_2` abaixo (o comentário no
# resource dela mostra exatamente o que remover).
#
# Os dois resources continuam sendo dois `kubectl_manifest` fixos (em vez
# de um único ApplicationSet com list generator de 2 itens) só por
# simplicidade/consistência com o padrão hardcoded por shard já usado em
# nodeclasses.tf/nodepools.tf — agora que o syncPolicy é idêntico nas duas,
# um list generator também funcionaria, mas não há necessidade de refatorar.
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

# Shard 2 — agora com auto-sync igual à shard-1 (decisão explícita do
# usuário, ver comentário no topo do arquivo). Para voltar à aprovação
# manual original do desafio, REMOVA o bloco `automated:` abaixo (mantendo
# só `syncOptions`), igual era antes.
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
