# WorkflowTemplate reutilizável: build+push da imagem no ECR (Kaniko), atualização de apps/springboot/values.yaml no Git, e a promoção
# controlada entre shards — manual OU automática via CloudWatch Alarm, escolhido em tempo de execução por um campo do PRÓPRIO
# apps/springboot/values.yaml (promotion.automaticApproval). Disparo do Workflow em si continua sempre MANUAL/por polling (veja
# argoworkflows-poller.tf) — não há Argo Events/webhook nenhum "escutando" o repositório.
#
# spec.templates.build-and-deploy é um DAG (não "steps") de propósito: a partir do passo 5 o fluxo se ramifica (automático vs. manual) e as duas
# ramificações convergem de volta num único "promote-shard2" — isso é mais natural de expressar com dependências (depends/when) do que com uma
# lista sequencial de "steps".
#
# Tarefas (spec.templates.build-and-deploy.dag.tasks):
#   1. clone-repo             — clona var.github_repo_url (público) num volume compartilhado entre os passos (PVC,
#                                não emptyDir, porque cada passo do Argo Workflows roda num Pod separado); captura
#                                o commit SHA curto (tag da imagem) e também lê promotion.automaticApproval /
#                                promotion.cloudWatchAlarmName do values.yaml recém-clonado — assim o resto
#                                do Workflow decide o caminho sem precisar de mais nenhum step só pra isso.
#   2. maven-build            — `mvn clean package` dentro de apps/.
#   3. kaniko-build-push      — builda apps/Dockerfile com Kaniko e dá push
#                                no ECR. SEM Docker-in-Docker.
#   4. update-values          — atualiza image.repository/image.tag em
#                                apps/springboot/values.yaml e dá git
#                                commit+push — dispara o sync automático da
#                                shard-1 no ArgoCD.
#   5. wait-shard1-healthy    — espera o Rollout da shard-1 chegar a
#                                "Healthy" (canário promovido a 100%
#                                manualmente por você, com
#                                `kubectl argo rollouts promote`).
#   6a. check-cloudwatch-alarm — SÓ roda se promotion.automaticApproval
#                                for "true": consulta o StateValue do
#                                alarme (cloudwatch-alarm.tf) via AWS CLI.
#   6b. approve-shard2-promotion — SÓ roda se automaticApproval for
#                                "false": template "suspend: {}" nativo do
#                                Argo Workflows — fica parado até alguém
#                                clicar "Resume" na UI (ou `argo resume`).
#   7a. promote-shard2         — roda depois de 6a com estado "OK", OU
#                                depois de 6b aprovado: dá
#                                `kubectl patch application
#                                springboot-shard-2` (mesmo comando
#                                fallback documentado no
#                                TESTE-END-TO-END.md).
#   7b. rollback-shard1        — roda depois de 6a com estado != "OK"
#                                (ALARM ou INSUFFICIENT_DATA — fail
#                                closed): aborta o Rollout da shard-1 via
#                                patch no subresource status, devolvendo
#                                100% do tráfego pra versão anterior
#                                (stable) sem precisar de novo commit.
#
# ATENÇÃO: a combinação depends/when das tarefas 6-7 (pra fazer as duas
# ramificações convergirem em promote-shard2, mesmo com uma delas sempre
# "Skipped") é a parte mais delicada desse arquivo — funciona pela lógica
# do Argo Workflows, mas não foi validada rodando de verdade. Teste os 3
# cenários (automático=OK, automático=ALARM, manual) antes de confiar nisso
# em qualquer coisa que não seja este ambiente de teste.
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
            # "gp2" (StorageClass padrão de qualquer cluster EKS) NÃO
            # funciona no Auto Mode: seu provisioner legado
            # "kubernetes.io/aws-ebs" migra (CSI migration) para
            # "ebs.csi.aws.com", o driver EBS CSI "clássico" — que não roda
            # no Auto Mode (lá o driver é 100% gerenciado pela AWS, sem pod
            # visível). O PVC fica preso pra sempre em Pending esperando um
            # provisioner que não existe. O Auto Mode usa um provisioner
            # PRÓPRIO, "ebs.csi.eks.amazonaws.com", e — ao contrário do que
            # o nome "block storage capability" sugere — não cria nenhuma
            # StorageClass sozinho; "auto-ebs-sc" é criada explicitamente em
            # storageclass.tf (kubectl_manifest.storageclass_auto_ebs).
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

              # Só executa se promotion.automaticApproval == "true" no
              # values.yaml clonado no passo 1.
              - name: check-cloudwatch-alarm
                depends: "wait-shard1-healthy"
                template: check-cloudwatch-alarm
                arguments:
                  parameters:
                    - name: alarm-name
                      value: "{{tasks.clone-repo.outputs.parameters.alarm-name}}"
                when: "{{tasks.clone-repo.outputs.parameters.auto-approval}} == true"

              # Só executa se promotion.automaticApproval == "false".
              - name: approve-shard2-promotion
                depends: "wait-shard1-healthy"
                template: approve-shard2-promotion
                when: "{{tasks.clone-repo.outputs.parameters.auto-approval}} == false"

              # Converge as duas ramificações: dispara se o alarme veio OK (caminho automático) OU se a aprovação manual foi resumida
              # com sucesso (caminho manual). O "|| *.Skipped" em cada lado do "depends" é necessário porque exatamente uma das duas
              # tarefas acima sempre fica Skipped (quando o "when" dela é  falso) — sem isso, o depends padrão (que exige Succeeded)
              # nunca seria satisfeito.
              - name: promote-shard2
                depends: >-
                  (check-cloudwatch-alarm.Succeeded || check-cloudwatch-alarm.Skipped)
                  && (approve-shard2-promotion.Succeeded || approve-shard2-promotion.Skipped)
                template: sync-shard2
                when: >-
                  {{tasks.check-cloudwatch-alarm.outputs.parameters.state}} == OK
                  || {{tasks.approve-shard2-promotion.status}} == Succeeded

              # Só entra na jogada se check-cloudwatch-alarm de fato rodou
              # (senão, no modo manual, ela fica Skipped e esta tarefa
              # também é automaticamente pulada — comportamento desejado,
              # rollback automático não deve existir no modo manual).
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

                # Lê o toggle manual/automático direto do values.yaml
                # recém-clonado (apps/springboot/values.yaml,
                # bloco "promotion:") — dá pra trocar de modo só com um
                # commit, sem reaplicar Terraform.
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
          # Kaniko builda a imagem sem precisar de um daemon Docker (nada de
          # Docker-in-Docker). Para autenticar no ECR ele usa o helper de
          # credenciais nativo da AWS SDK, detectado automaticamente pelo
          # hostname "*.dkr.ecr.*.amazonaws.com" no destino — como o pod
          # roda com a ServiceAccount com IRSA (kubernetes_service_account.argo_workflow_ecr_push,
          # argoworkflows-irsa.tf), o webhook do EKS injeta
          # AWS_ROLE_ARN/AWS_WEB_IDENTITY_TOKEN_FILE automaticamente, sem
          # nenhum passo extra de "docker login"/aws ecr get-login-password.
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
          # Sem "activeDeadlineSeconds" de propósito: o operador ainda
          # precisa promover manualmente os 2 estágios do canário da
          # shard-1 (kubectl argo rollouts promote springboot -n shard-1),
          # o que pode levar o tempo que for necessário.
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
                  echo "promotion.cloudWatchAlarmName não configurado no values.yaml — tratando como INSUFFICIENT_DATA (fail-closed)." >&2
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
          # Gate de aprovação manual: o Workflow fica "Running" (Suspended)
          # aqui até alguém rodar:
          #   argo resume <nome-do-workflow> -n argo-workflows
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
          # Aborta o Rollout em andamento — o Argo Rollouts devolve 100% do
          # tráfego pra versão "stable" (anterior) imediatamente, sem
          # precisar de um novo commit/push. Usa patch no subresource
          # "status" (kubectl >= 1.24) porque o CRD do Rollout declara
          # status como subresource — um patch comum, sem
          # --subresource=status, é silenciosamente ignorado pela API do
          # Kubernetes nesse campo.
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
