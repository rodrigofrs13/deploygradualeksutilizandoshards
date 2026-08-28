# WorkflowTemplate: build+push da imagem (Kaniko), atualização do values.yaml no Git, e promoção shard-1 -> shard-2 (manual ou automática via
# CloudWatch, toggle em apps/springboot/values.yaml). Ver README, "CI: Argo Workflows" e "Promoção shard-1 -> shard-2" para o fluxo completo, os 8
# passos do DAG e o aviso sobre a lógica depends/when não estar validada em execução real.
resource "kubectl_manifest" "argo_workflow_template" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: WorkflowTemplate
    metadata:
      name: build-push-springboot
      namespace: ${local.argo_workflows_namespace}
    spec:
      entrypoint: build-and-deploy
      serviceAccountName: ${local.argo_workflow_sa_name}

      arguments:
        parameters:
          - name: ecr-repository-url
            value: "${local.ecr_repository_url}"
          - name: github-repo-url
            value: "${var.github_repo_url}"
          - name: git-branch
            value: "main"

      volumeClaimTemplates:
        - metadata:
            name: workspace
          spec:
            # StorageClass própria — EKS Auto Mode não cria uma sozinho. Ver README, "Notas / problemas conhecidos".
            storageClassName: auto-ebs-sc
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 2Gi

      templates:
        - name: build-and-deploy
          dag:
            tasks:
              - name: clone-repo
                template: clone-repo

              - name: maven-build
                depends: "clone-repo"
                template: maven-build

              - name: kaniko-build-push
                depends: "maven-build"
                template: kaniko-build-push
                arguments:
                  parameters:
                    - name: image-tag
                      value: "{{tasks.clone-repo.outputs.parameters.image-tag}}"

              - name: update-values
                depends: "kaniko-build-push"
                template: update-values
                arguments:
                  parameters:
                    - name: image-tag
                      value: "{{tasks.clone-repo.outputs.parameters.image-tag}}"

              - name: wait-shard1-healthy
                depends: "update-values"
                template: wait-shard1-healthy

              # Só roda se promotion.automaticApproval == "true" no values.yaml clonado (task clone-repo).
              - name: check-cloudwatch-alarm
                depends: "wait-shard1-healthy"
                template: check-cloudwatch-alarm
                arguments:
                  parameters:
                    - name: alarm-name
                      value: "{{tasks.clone-repo.outputs.parameters.alarm-name}}"
                when: "{{tasks.clone-repo.outputs.parameters.auto-approval}} == true"

              # Só roda se promotion.automaticApproval == "false".
              - name: approve-shard2-promotion
                depends: "wait-shard1-healthy"
                template: approve-shard2-promotion
                when: "{{tasks.clone-repo.outputs.parameters.auto-approval}} == false"

              # Converge as duas ramificações — ver README pra explicação do "|| *.Skipped".
              - name: promote-shard2
                depends: >-
                  (check-cloudwatch-alarm.Succeeded || check-cloudwatch-alarm.Skipped)
                  && (approve-shard2-promotion.Succeeded || approve-shard2-promotion.Skipped)
                template: sync-shard2
                when: >-
                  {{tasks.check-cloudwatch-alarm.outputs.parameters.state}} == OK
                  || {{tasks.approve-shard2-promotion.status}} == Succeeded

              - name: rollback-shard1
                depends: "check-cloudwatch-alarm"
                template: rollback-shard1
                when: "{{tasks.check-cloudwatch-alarm.outputs.parameters.state}} != OK"

        - name: clone-repo
          outputs:
            parameters:
              - name: image-tag
                valueFrom:
                  path: /tmp/image-tag
              - name: auto-approval
                valueFrom:
                  path: /tmp/auto-approval
              - name: alarm-name
                valueFrom:
                  path: /tmp/alarm-name
          container:
            image: alpine/git:2.45.2
            command: ["sh", "-c"]
            args:
              - |
                set -e
                rm -rf /workspace/repo
                git clone --depth 1 --branch "{{workflow.parameters.git-branch}}" "{{workflow.parameters.github-repo-url}}" /workspace/repo
                cd /workspace/repo
                git rev-parse --short HEAD > /tmp/image-tag

                # Lê o toggle promotion.automaticApproval/cloudWatchAlarmName do values.yaml recém-clonado.
                AUTO=$(grep -A2 '^promotion:' apps/springboot/values.yaml 2>/dev/null | grep 'automaticApproval:' | awk '{print $2}')
                ALARM=$(grep -A2 '^promotion:' apps/springboot/values.yaml 2>/dev/null | grep 'cloudWatchAlarmName:' | awk '{print $2}' | tr -d '"')
                echo "promotion.automaticApproval lido do values.yaml: $${AUTO:-<vazio, tratando como false>}"
                echo -n "$${AUTO:-false}" > /tmp/auto-approval
                echo -n "$${ALARM:-}" > /tmp/alarm-name
            volumeMounts:
              - name: workspace
                mountPath: /workspace

        - name: maven-build
          container:
            image: maven:3.9-eclipse-temurin-17
            command: ["sh", "-c"]
            args:
              - |
                set -e
                cd /workspace/repo/apps
                mvn -B -q clean package -DskipTests
            volumeMounts:
              - name: workspace
                mountPath: /workspace

        - name: kaniko-build-push
          inputs:
            parameters:
              - name: image-tag
          # Kaniko builda sem Docker-in-Docker; autentica no ECR via IRSA (kubernetes_service_account.argo_workflow_ecr_push).
          container:
            image: gcr.io/kaniko-project/executor:v1.23.2
            args:
              - --dockerfile=/workspace/repo/apps/Dockerfile
              - --context=/workspace/repo/apps
              - --destination={{workflow.parameters.ecr-repository-url}}:{{inputs.parameters.image-tag}}
            env:
              - name: AWS_REGION
                value: "${var.aws_region}"
            volumeMounts:
              - name: workspace
                mountPath: /workspace

        - name: update-values
          inputs:
            parameters:
              - name: image-tag
          container:
            image: alpine/git:2.45.2
            env:
              - name: GIT_USERNAME
                valueFrom:
                  secretKeyRef:
                    name: git-push-credentials
                    key: username
              - name: GIT_TOKEN
                valueFrom:
                  secretKeyRef:
                    name: git-push-credentials
                    key: token
            command: ["sh", "-c"]
            args:
              - |
                set -e
                cd /workspace/repo
                sed -i "s#^  repository: .*#  repository: {{workflow.parameters.ecr-repository-url}}#" apps/springboot/values.yaml
                sed -i "s#^  tag: .*#  tag: \"{{inputs.parameters.image-tag}}\"#" apps/springboot/values.yaml
                git config user.email "argo-workflows@cluster.local"
                git config user.name "argo-workflows"
                git add apps/springboot/values.yaml
                git commit -m "Commit: bump image to {{inputs.parameters.image-tag}} [argo-workflows]" || echo "nada para commitar"
                REPO_URL="{{workflow.parameters.github-repo-url}}"
                PUSH_URL="https://$${GIT_USERNAME}:$${GIT_TOKEN}@$${REPO_URL#https://}"
                git push "$PUSH_URL" "HEAD:{{workflow.parameters.git-branch}}"
            volumeMounts:
              - name: workspace
                mountPath: /workspace

        - name: wait-shard1-healthy
          # Sem activeDeadlineSeconds: espera a promoção manual do canário da shard-1 pelo tempo que for necessário.
          container:
            image: alpine/k8s:1.30.0
            command: ["sh", "-c"]
            args:
              - |
                set -e
                echo "Aguardando o Rollout da shard-1 chegar a Healthy..."
                while true; do
                  PHASE=$(kubectl get rollout springboot -n shard-1 -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                  echo "  fase atual: $${PHASE:-<ainda não existe>}"
                  [ "$PHASE" = "Healthy" ] && break
                  sleep 15
                done
                echo "Shard-1 está Healthy."

        - name: check-cloudwatch-alarm
          inputs:
            parameters:
              - name: alarm-name
          outputs:
            parameters:
              - name: state
                valueFrom:
                  path: /tmp/alarm-state
          container:
            image: alpine/k8s:1.30.0
            command: ["sh", "-c"]
            args:
              - |
                set -e
                ALARM_NAME="{{inputs.parameters.alarm-name}}"
                if [ -z "$ALARM_NAME" ]; then
                  echo "promotion.cloudWatchAlarmName não configurado — tratando como INSUFFICIENT_DATA (fail-closed)." >&2
                  echo -n "INSUFFICIENT_DATA" > /tmp/alarm-state
                  exit 0
                fi
                STATE=$(aws cloudwatch describe-alarms \
                  --alarm-names "$ALARM_NAME" --region "${var.aws_region}" \
                  --query "MetricAlarms[0].StateValue" --output text 2>/dev/null)
                if [ -z "$STATE" ] || [ "$STATE" = "None" ]; then
                  echo "Não foi possível ler o estado do alarme '$ALARM_NAME' — tratando como INSUFFICIENT_DATA (fail-closed)." >&2
                  STATE="INSUFFICIENT_DATA"
                fi
                echo "Estado do alarme '$ALARM_NAME': $STATE"
                echo -n "$STATE" > /tmp/alarm-state

        - name: approve-shard2-promotion
          # Gate manual: Workflow fica Suspended até "argo resume" (ou o botão na UI). Ver README.
          suspend: {}

        - name: sync-shard2
          container:
            image: alpine/k8s:1.30.0
            command: ["sh", "-c"]
            args:
              - |
                set -e
                echo "Sincronizando springboot-shard-2..."
                kubectl patch application springboot-shard-2 -n argocd --type merge \
                  -p '{"operation":{"sync":{"revision":"HEAD"}}}'
                echo "Sync disparado. Acompanhe com: kubectl get application springboot-shard-2 -n argocd -w"

        - name: rollback-shard1
          # Aborta o Rollout via patch no subresource status — devolve 100% do tráfego pra stable sem novo commit.
          container:
            image: alpine/k8s:1.30.0
            command: ["sh", "-c"]
            args:
              - |
                set -e
                echo "Alarme não OK — abortando o Rollout da shard-1 (rollback automático)..."
                kubectl patch rollout springboot -n shard-1 --type merge \
                  --subresource status -p '{"status":{"abort":true}}'
                echo "Shard-1 abortada — tráfego voltou 100% pra versão anterior (stable)."
  YAML

  depends_on = [
    helm_release.argo_workflows,
    kubernetes_service_account.argo_workflow_ecr_push,
    kubernetes_secret.git_push_credentials,
    kubernetes_cluster_role_binding.argo_workflow_rollouts_reader,
    kubernetes_role_binding.argo_workflow_argocd_sync,
    aws_iam_role_policy.argo_workflow_cloudwatch_read,
  ]
}
