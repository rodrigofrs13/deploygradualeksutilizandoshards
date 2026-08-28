# CronWorkflow que dispara o build-push-springboot automaticamente via polling do Git (a cada X min), em vez de precisar de `argo submit` manual
# ou de um webhook (Argo Events). 
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

# check-repo compara o SHA atual com o último processado (ConfigMap git-poll-state) e só considera "mudou" se houver diff em apps/ além do
# próprio apps/springboot/values.yaml (evita loop de auto-disparo — ver README).
resource "kubectl_manifest" "argo_workflow_poller_cronworkflow" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: CronWorkflow
    metadata:
      name: git-poll-trigger
      namespace: ${local.argo_workflows_namespace}
    spec:
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
                    echo "true" > /tmp/changed
                  else
                    git clone --quiet --branch "{{workflow.parameters.git-branch}}" \
                      --single-branch "{{workflow.parameters.github-repo-url}}" /tmp/repo
                    cd /tmp/repo
                    CHANGED_FILES=$(git diff --name-only "$LAST" "$LATEST" -- apps/ 2>/dev/null || echo "")
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
