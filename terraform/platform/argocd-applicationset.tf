# Um único ApplicationSet controla o deploy nas duas shards 
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
                  targetRevision: HEAD # sempre a última revisão do branch padrão do repositório
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
            # Sem "template": herda o syncPolicy do template top-level (sem automated) — aprovação manual pra essa shard.
      template:
        metadata:
          name: 'springboot-{{ .shard }}'
        spec:
          project: ${var.argocd_project_name}
          source:
            repoURL: ${var.github_repo_url}
            targetRevision: HEAD # sempre a última revisão do branch padrão do repositório
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
