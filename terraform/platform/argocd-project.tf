# AppProject do ArgoCD — restringe quais repositórios e destinos as
# Applications geradas pelo ApplicationSet podem usar.
resource "kubectl_manifest" "argocd_project" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: ${var.argocd_project_name}
      namespace: argocd
    spec:
      description: "Apps do cluster ${var.cluster_name} (arquitetura em shards)"

      sourceRepos:
        - ${var.github_repo_url}

      destinations:
        - namespace: "*"
          server: https://kubernetes.default.svc

      clusterResourceWhitelist:
        - group: "*"
          kind: "*"

      namespaceResourceWhitelist:
        - group: "*"
          kind: "*"
  YAML

  depends_on = [
    helm_release.argocd
  ]
}
