# Espera o cluster ficar pronto. 
resource "time_sleep" "wait_for_eks" {
  depends_on = [
    data.aws_eks_cluster.this
  ]

  create_duration = "120s"
}


# Cria namespace
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      name = "argocd"
    }
  }

  depends_on = [time_sleep.wait_for_eks]
}

# Chart oficial argo-cd (argo-helm). Values em ./environment/dev/argocd.yaml 
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.4.0"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  values     = [file("./environment/dev/argocd.yaml")]

  cleanup_on_fail = true # Se um helm install falhar no meio do caminho ele deixa pra trás os recursos que já chegou a criar e marca o release como failed. 
  # Da próxima vez que você rodar terraform apply, o Helm tenta fazer upgrade em cima desse release "sujo" e frequentemente trava com erro de conflito.

  depends_on = [time_sleep.wait_for_eks]
}
