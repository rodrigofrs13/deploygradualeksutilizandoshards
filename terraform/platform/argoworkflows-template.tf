# WorkflowTemplate reutilizável: build+push da imagem no ECR (Kaniko),
# atualização de apps/springboot/values.yaml no Git, e a promoção
# controlada entre shards. Disparo é sempre MANUAL (não há Argo
# Events/webhook nenhum "escutando" o repositório) — veja o comando
# `argo submit` no README.
#
# Passos (spec.templates.build-and-deploy.steps):
#   1. clone-repo             — clona var.github_repo_url (público) num
#                                volume compartilhado entre os passos (PVC,
#                                não emptyDir, porque cada passo do Argo
#                                Workflows roda num Pod separado) e captura
#                                o commit SHA curto como tag da imagem.
#   2. maven-build            — `mvn clean package` dentro de apps/, gerando
#                                apps/target/springboot-sharded-app-1.0.0.jar
#                                (o Dockerfile só copia o jar, não builda a
#                                app — por isso o build Maven precisa rodar
#                                ANTES do Kaniko).
#   3. kaniko-build-push      — builda apps/Dockerfile com Kaniko e dá push
#                                no ECR usando a tag do passo 1. SEM
#                                Docker-in-Docker.
#   4. update-values          — atualiza image.repository/image.tag em
#                                apps/springboot/values.yaml e dá git
#                                commit+push — é esse push que o ArgoCD
#                                (syncPolicy.automated só na shard-1,
#                                argocd-applicationset.tf) detecta e
#                                sincroniza, disparando o canário na shard 1.
#   5. wait-shard1-healthy    — espera o Rollout da shard-1 chegar a
#                                "Healthy" (ou seja, até você terminar de
#                                promover manualmente os 4 estágios do
#                                canário — apps/springboot/values.yaml,
#                                canary.steps). Antes deste step, nada
#                                impedia rodar o sync da shard-2 com a
#                                shard-1 ainda no meio do canário (ver
#                                README, "Entre shards").
#   6. approve-shard2-promotion — gate de aprovação manual de verdade:
#                                template "suspend: {}" nativo do Argo
#                                Workflows. O Workflow fica parado
#                                (Running/Suspended) até alguém rodar
#                                `argo resume <nome-do-workflow> -n
#                                argo-workflows`. Equivalente, dentro do
#                                pipeline, ao "pause: {}" sem duration do
#                                Argo Rollouts — nenhuma promoção automática
#                                por tempo.
#   7. sync-shard2            — só depois do resume: dá
#                                `kubectl patch application
#                                springboot-shard-2` (mesmo comando
#                                fallback documentado em
#                                TESTE-END-TO-END.md), disparando o sync e,
#                                com isso, o canário (independente) da
#                                shard 2.
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
          steps:
            - - name: clone-repo
                template: clone-repo
            - - name: maven-build
                template: maven-build
            - - name: kaniko-build-push
                template: kaniko-build-push
                arguments:
                  parameters:
                    - name: image-tag
                      value: "{{steps.clone-repo.outputs.parameters.image-tag}}"
            - - name: update-values
                template: update-values
                arguments:
                  parameters:
                    - name: image-tag
                      value: "{{steps.clone-repo.outputs.parameters.image-tag}}"
            - - name: wait-shard1-healthy
                template: wait-shard1-healthy
            - - name: approve-shard2-promotion
                template: approve-shard2-promotion
            - - name: sync-shard2
                template: sync-shard2

        - name: clone-repo
          outputs:
            parameters:
              - name: image-tag
                valueFrom:
                  path: /tmp/image-tag
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
          # precisa promover manualmente cada um dos 4 estágios do canário
          # da shard-1 (kubectl argo rollouts promote springboot -n
          # shard-1), o que pode levar o tempo que for necessário — mesma
          # filosofia do "pause: {}" sem duration em
          # apps/springboot/values.yaml.
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
                echo "Shard-1 está Healthy — pronto para aprovar a promoção da shard-2."

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
                echo "Aprovado — sincronizando springboot-shard-2..."
                kubectl patch application springboot-shard-2 -n argocd --type merge \
                  -p '{"operation":{"sync":{"revision":"HEAD"}}}'
                echo "Sync disparado. Acompanhe com: kubectl get application springboot-shard-2 -n argocd -w"
  YAML

  depends_on = [
    helm_release.argo_workflows,
    kubernetes_service_account.argo_workflow_ecr_push,
    kubernetes_secret.git_push_credentials,
    kubernetes_cluster_role_binding.argo_workflow_rollouts_reader,
    kubernetes_role_binding.argo_workflow_argocd_sync,
  ]
}
