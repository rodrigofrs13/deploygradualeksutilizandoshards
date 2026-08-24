# Controla o deploy da app nas duas shards com um ÚNICO ApplicationSet do
# ArgoCD (requisito do desafio: "utilizar um ApplicationSet do ArgoCD para
# controlar o deploy da aplicação entre as shards") — não mais dois
# ApplicationSets separados. `spec.generators` tem DOIS generators `list`,
# cada um com 1 elemento (`shard: shard-1` / `shard: shard-2`); os dois
# alimentam o MESMO `spec.template` de baixo (`goTemplate: true`, então os
# parâmetros são acessados como `{{ .shard }}`).
#
# Aprovação manual entre shards (requisito do desafio) apesar de um único
# ApplicationSet: o generator da shard-1 tem seu PRÓPRIO `template` (aninhado
# dentro do `list:`), que sobrescreve só `spec.syncPolicy` do template
# top-level — official docs
# (https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Template/#generator-templates):
# "the generator's template field takes precedence over the spec's template
# fields (...) if only one of those templates' fields has a value, that
# value will be used". O generator da shard-2 NÃO tem `template` nenhum,
# então herda o `syncPolicy` do template top-level, que só tem
# `syncOptions` — SEM `automated`. Resultado: shard-1 sincroniza sozinha,
# shard-2 fica `OutOfSync` até `argocd app sync springboot-shard-2` (ou o
# `kubectl patch` equivalente, veja o README) — igual ao comportamento
# anterior com dois ApplicationSets, só que agora com um único recurso.
#
# Por que o `template` do generator da shard-1 restata TUDO (metadata,
# project, source, destination — não só o `syncPolicy` que difere): na
# prática, o CRD `ApplicationSet` valida o `template` de um generator contra
# o schema INTEIRO de `ApplicationSetTemplate` assim que ele existe — ou
# seja, se o generator define `template`, `metadata`/`spec.project`/
# `spec.destination` viram "Required value" nesse ponto, mesmo que o
# controller depois faça merge com o `spec.template` de baixo em tempo de
# reconciliação. Só sobrescrever `spec.syncPolicy` (deixando o resto de
# fora) falha na admissão do Kubernetes com "spec.generators[0].list.
# template.spec.destination: Required value" (e o mesmo pra `project` e
# `metadata`) — foi exatamente o erro visto ao aplicar. Por isso o
# `template` da shard-1 é uma cópia completa e autossuficiente do template
# top-level, só com `syncPolicy.automated` adicionado.
#
# Por que não um único `list` generator com 2 elementos (a forma mais óbvia
# de "uma lista de 2 elementos"): o override de `template` é por GENERATOR,
# não por elemento dentro da lista de um mesmo generator — um único
# generator `list` com elementos `shard-1`/`shard-2` aplicaria o MESMO
# `template` (ou a ausência dele) aos dois, sem jeito de variar o
# `syncPolicy` por elemento. Por isso são dois generators `list` (um por
# shard, cada um com 1 elemento) dentro do MESMO ApplicationSet — ainda um
# único recurso Kubernetes, só que com `spec.generators` de 2 itens em vez
# de `spec.generators[0].list.elements` de 2 itens.
#
# O canário DENTRO de cada shard é feito pelo Argo Rollouts (recurso
# Rollout em apps/springboot/templates/rollout.yaml, com os passos definidos
# em apps/springboot/values.yaml canary.steps) — precisa do Argo Rollouts
# instalado (argorollouts.tf) para o CRD `Rollout` existir no cluster.
resource "kubectl_manifest" "argocd_applicationset" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: ApplicationSet
    metadata:
      name: springboot-shards
      namespace: argocd
    spec:
      goTemplate: true
      generators:
        - list:
            elements:
              - shard: shard-1
            template:
              metadata:
                name: 'springboot-{{ .shard }}'
              spec:
                project: ${var.argocd_project_name}
                source:
                  repoURL: ${var.github_repo_url}
                  targetRevision: HEAD
                  path: ${var.argocd_apps_path}
                  helm:
                    parameters:
                      - name: shard
                        value: '{{ .shard }}'
                      - name: namespace
                        value: '{{ .shard }}'
                destination:
                  server: https://kubernetes.default.svc
                  namespace: '{{ .shard }}'
                syncPolicy:
                  automated:
                    prune: true
                    selfHeal: true
                  syncOptions:
                    - CreateNamespace=true
        - list:
            elements:
              - shard: shard-2
            # SEM "template" aqui de propósito: herda spec.syncPolicy do
            # template top-level (abaixo), que não tem "automated" —
            # aprovação manual pra essa shard.
      template:
        metadata:
          name: 'springboot-{{ .shard }}'
        spec:
          project: ${var.argocd_project_name}
          source:
            repoURL: ${var.github_repo_url}
            targetRevision: HEAD
            path: ${var.argocd_apps_path}
            helm:
              parameters:
                - name: shard
                  value: '{{ .shard }}'
                - name: namespace
                  value: '{{ .shard }}'
          destination:
            server: https://kubernetes.default.svc
            namespace: '{{ .shard }}'
          syncPolicy:
            syncOptions:
              - CreateNamespace=true
  YAML

  depends_on = [
    kubectl_manifest.argocd_project
  ]
}
