# Controla o deploy gradual da app ENTRE as shards: DUAS ApplicationSets do
# ArgoCD (uma por shard), ambas apontando pro mesmo chart Helm
# (var.argocd_apps_path = apps/springboot), com "shard"/"namespace"
# sobrescritos via spec.source.helm.parameters.
#
# Por que dois resources fixos em vez de UM ApplicationSet com um list
# generator de 2 itens (que foi a primeira tentativa aqui): o Go template do
# ApplicationSet (goTemplate: true) só substitui VALORES escalares dentro de
# campos já existentes (ex.: metadata.name, source.path) — ele não consegue
# incluir/omitir uma chave inteira condicionalmente (ex.: um `{{if}}` em
# volta de `syncPolicy.automated`). E mesmo que pudesse, o yaml_body inteiro
# precisa ser YAML válido ANTES de qualquer template rodar, porque é assim
# que o provider kubectl e a API do Kubernetes leem o manifesto. Um
# `{{- if eq .autoSync "true" }}` sozinho no meio de um mapping YAML não é
# YAML válido → erro "did not find expected node content". Por isso, para
# "shard-1 sincroniza sozinha, shard-2 exige aprovação manual" (a única
# diferença real entre elas é a chave syncPolicy.automated existir ou não),
# usamos dois ApplicationSets separados e totalmente estáticos — mesmo
# padrão hardcoded por shard já usado em nodeclasses.tf/nodepools.tf.
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

# Shard 2 — SEM syncPolicy.automated: fica "OutOfSync" até alguém rodar
# `argocd app sync springboot-shard-2` (ou clicar em "Sync" na UI/CLI do
# ArgoCD). Essa ausência da chave "automated" é a aprovação manual entre
# shards exigida pelo desafio.
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
