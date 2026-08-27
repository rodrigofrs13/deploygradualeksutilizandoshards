# Dispara o WorkflowTemplate build-push-springboot automaticamente depois
# de um `git push`, sem precisar rodar `argo submit` manualmente.
#
# Decisão de arquitetura (Opção "B" apresentada ao usuário, escolhida no
# lugar de Argo Events + webhook do GitHub): um CronWorkflow com POLLING em
# vez de um webhook. Motivo: polling não precisa expor nenhum endpoint novo
# à internet nem instalar componentes novos (Argo Events: EventBus,
# EventSource, Sensor) — é só o próprio cluster puxando informação do
# GitHub (`git ls-remote`, outbound), nunca o GitHub empurrando pra dentro
# do cluster (inbound). Trade-off: não é instantâneo, tem o atraso do
# intervalo do polling (aqui, até 2 minutos) — para uma Demo é irrelevante.
# Se um dia precisar de disparo instantâneo, o caminho é trocar este
# arquivo por Argo Events (webhook do GitHub) — nesse caso o NLB do Argo
# Workflows (environment/dev/argo-workflows.yaml) já está com
# `aws-load-balancer-scheme: internet-facing`, então o endpoint do webhook
# ficaria alcançável pelo GitHub sem mudança adicional de exposição.
#
# Como funciona o CronWorkflow "git-poll-trigger" (roda a cada 2 min):
#   1. check-repo    — `git ls-remote` no branch configurado (repositório
#                       público, sem credencial) pra pegar o SHA atual do
#                       HEAD, e só considera que "mudou" se, comparado ao
#                       último SHA já processado (lido de um ConfigMap
#                       "git-poll-state", montado como volume — `optional:
#                       true` pra não falhar na primeírissima execução),
#                       o `git diff --name-only` entre os dois SHAs tiver
#                       algum arquivo sob `apps/` **além** de
#                       `apps/springboot/values.yaml` sozinho.
#
#                       Duas exclusões deliberadas, ambas pra evitar builds
#                       desnecessários:
#                       (a) commit fora de `apps/` (README, Terraform,
#                           scripts, docs) — não deve rebuildar a imagem;
#                       (b) commit que só mexe em
#                           `apps/springboot/values.yaml` — é exatamente o
#                           arquivo que o PRÓPRIO Workflow reescreve no
#                           passo `update-values` (bump de
#                           `image.tag`/commit+push automático, veja
#                           argoworkflows-template.tf). Sem essa exclusão,
#                           esse commit automático seria visto como "mudança
#                           nova" no próximo poll e disparava outro build,
#                           que faria outro bump, ad infinitum — um LOOP DE
#                           AUTO-DISPARO (foi exatamente o que causou a
#                           enxurrada de `git-triggered-build-*` observada
#                           rodando quase a cada 2 minutos por horas).
#   2. update-state  — só roda se mudou de verdade (`when`): grava o novo
#                       SHA no ConfigMap "git-poll-state" via
#                       `resource: apply` (nativo do Argo Workflows, sem
#                       precisar de kubectl dentro do container).
#   3. trigger-build — só roda se mudou de verdade (`when`): cria um novo
#                       `Workflow` a partir do MESMO WorkflowTemplate
#                       build-push-springboot usado pelo `argo submit`
#                       manual (argoworkflows-template.tf) — reaproveita os
#                       parâmetros default definidos lá (ecr-repository-url,
#                       github-repo-url, git-branch).
#
# ServiceAccount própria e mínima (sem IRSA — este CronWorkflow só lê um
# repositório público e cria objetos do Kubernetes, nunca fala com o ECR):
#   - workflowtaskresults: create/patch — exigido de QUALQUER ServiceAccount
#     usada num Workflow desde o Argo Workflows v3.4 (mesmo motivo do Role
#     "argo-workflow-executor" em argoworkflows-irsa.tf, só que aqui é uma
#     ServiceAccount diferente, então precisa do próprio Role/RoleBinding).
#   - configmaps: get/list/create/update/patch — pra ler/gravar o estado do
#     último SHA processado.
#   - workflows.argoproj.io: create/get — pra criar o Workflow que dispara
#     o build.
resource "kubernetes_service_account" "argo_workflow_poller" {
  metadata {
    name      = "argo-workflow-poller"
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }

  depends_on = [kubernetes_namespace.argo_workflows]
}

resource "kubernetes_role" "argo_workflow_poller" {
  metadata {
    name      = "argo-workflow-poller"
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflowtaskresults"]
    verbs      = ["create", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "list", "create", "update", "patch"]
  }

  rule {
    api_groups = ["argoproj.io"]
    resources  = ["workflows"]
    verbs      = ["create", "get"]
  }

  depends_on = [kubernetes_namespace.argo_workflows]
}

resource "kubernetes_role_binding" "argo_workflow_poller" {
  metadata {
    name      = "argo-workflow-poller"
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.argo_workflow_poller.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argo_workflow_poller.metadata[0].name
    namespace = kubernetes_namespace.argo_workflows.metadata[0].name
  }
}

resource "kubectl_manifest" "argo_workflow_poller_cronworkflow" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: CronWorkflow
    metadata:
      name: git-poll-trigger
      namespace: ${local.argo_workflows_namespace}
    spec:
      # "schedules" (plural, lista) — não "schedule" (singular). A versão
      # do CRD instalada pelo chart argo-workflows já exige o campo novo
      # (spec.schedule ficou deprecated e a validação do CRD rejeita a
      # CronWorkflow com "spec.schedules: Required value" se só "schedule"
      # for enviado).
      schedules:
        - "*/15 * * * *"
      timezone: "UTC"
      concurrencyPolicy: "Forbid"
      startingDeadlineSeconds: 30
      successfulJobsHistoryLimit: 3
      failedJobsHistoryLimit: 3
      workflowSpec:
        serviceAccountName: ${kubernetes_service_account.argo_workflow_poller.metadata[0].name}
        entrypoint: check-and-trigger
        arguments:
          parameters:
            - name: github-repo-url
              value: "${var.github_repo_url}"
            - name: git-branch
              value: "main"

        templates:
          - name: check-and-trigger
            steps:
              - - name: check-repo
                  template: check-repo
              - - name: update-state
                  template: update-state
                  when: "{{steps.check-repo.outputs.parameters.changed}} == true"
                  arguments:
                    parameters:
                      - name: sha
                        value: "{{steps.check-repo.outputs.parameters.sha}}"
                - name: trigger-build
                  template: trigger-build
                  when: "{{steps.check-repo.outputs.parameters.changed}} == true"

          - name: check-repo
            outputs:
              parameters:
                - name: sha
                  valueFrom:
                    path: /tmp/sha
                - name: changed
                  valueFrom:
                    path: /tmp/changed
            container:
              image: alpine/git:2.45.2
              command: ["sh", "-c"]
              args:
                - |
                  set -e
                  LATEST=$(git ls-remote "{{workflow.parameters.github-repo-url}}" "refs/heads/{{workflow.parameters.git-branch}}" | awk '{print $1}')
                  LAST=$(cat /state/last-sha 2>/dev/null || echo "")
                  echo "$LATEST" > /tmp/sha

                  if [ -z "$LATEST" ]; then
                    echo "false" > /tmp/changed
                  elif [ "$LATEST" = "$LAST" ]; then
                    echo "false" > /tmp/changed
                  elif [ -z "$LAST" ]; then
                    # Primeira execução (ConfigMap "git-poll-state" ainda não
                    # existe): não tem SHA anterior pra comparar/diffar,
                    # builda uma vez só pra estabelecer a baseline.
                    echo "true" > /tmp/changed
                  else
                    git clone --quiet --branch "{{workflow.parameters.git-branch}}" \
                      --single-branch "{{workflow.parameters.github-repo-url}}" /tmp/repo
                    cd /tmp/repo
                    CHANGED_FILES=$(git diff --name-only "$LAST" "$LATEST" -- apps/ 2>/dev/null || echo "")
                    # Ignora se o ÚNICO arquivo alterado sob apps/ for o
                    # values.yaml que o próprio Workflow reescreve (bump de
                    # tag) -- ver comentário no topo do arquivo sobre o loop
                    # de auto-disparo que isso evita.
                    REAL_CHANGES=$(echo "$CHANGED_FILES" | grep -v -x "apps/springboot/values.yaml" || true)
                    if [ -n "$REAL_CHANGES" ]; then
                      echo "true" > /tmp/changed
                    else
                      echo "false" > /tmp/changed
                    fi
                    echo "arquivos sob apps/ no intervalo: $CHANGED_FILES"
                  fi
                  echo "ultimo processado: '$LAST' -- atual: '$LATEST' -- mudou: $(cat /tmp/changed)"
              volumeMounts:
                - name: state
                  mountPath: /state
            volumes:
              - name: state
                configMap:
                  name: git-poll-state
                  optional: true

          - name: update-state
            inputs:
              parameters:
                - name: sha
            resource:
              action: apply
              manifest: |
                apiVersion: v1
                kind: ConfigMap
                metadata:
                  name: git-poll-state
                  namespace: ${local.argo_workflows_namespace}
                data:
                  last-sha: "{{inputs.parameters.sha}}"

          - name: trigger-build
            resource:
              action: create
              manifest: |
                apiVersion: argoproj.io/v1alpha1
                kind: Workflow
                metadata:
                  generateName: git-triggered-build-
                  namespace: ${local.argo_workflows_namespace}
                spec:
                  workflowTemplateRef:
                    name: build-push-springboot
  YAML

  depends_on = [
    helm_release.argo_workflows,
    kubernetes_service_account.argo_workflow_poller,
    kubernetes_role_binding.argo_workflow_poller,
    kubectl_manifest.argo_workflow_template,
  ]
}
