# # Secret de credenciais de repositório do ArgoCD (formato oficial: label
# # argocd.argoproj.io/secret-type=repository + campo "type: git").
# # O provider "kubernetes" já faz o base64-encode automaticamente — os
# # valores abaixo são texto puro, equivalente a usar "stringData" via kubectl.
# resource "kubernetes_secret" "argocd_github_credentials" {
#   metadata {
#     name      = "argocd-github-credentials"
#     namespace = "argocd"

#     labels = {
#       "argocd.argoproj.io/secret-type" = "repository"
#     }
#   }

#   type = "Opaque"

#   data = {
#     type     = "git"
#     name     = "argocd-github"
#     url      = var.github_repo_url
#     username = var.github_username
#     password = var.github_token
#   }

#   depends_on = [helm_release.argocd]
# }
