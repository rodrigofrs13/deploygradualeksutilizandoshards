# O cluster já existe quando esta camada roda (ver README), então esperamos
# na data source em vez do resource aws_eks_cluster.this (que vive só no
# state da camada infra).
resource "time_sleep" "wait_for_eks" {
  depends_on = [
    data.aws_eks_cluster.this
  ]

  create_duration = "120s"
}

# Create the ArgoCD Namespace
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      name = "argocd"
    }
  }

  depends_on = [time_sleep.wait_for_eks]
}



# Deploy ArgoCD using Helm Release
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.4.0" # Use the latest stable chart version
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  # Caminho relativo a partir de terraform/platform — o arquivo continua em
  # terraform/infra/environment porque as duas camadas compartilham o mesmo
  # var-file/estrutura de ambiente (ver README).
  values = [file("./environment/dev/argocd.yaml")]

  # Prevents dirty Terraform state if the installation fails initially
  cleanup_on_fail = true

  depends_on = [time_sleep.wait_for_eks]
}
