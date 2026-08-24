# Copie este arquivo para "secrets.tfvars" (nome exato — já está no
# .gitignore via "environment/**/secrets.tfvars", nunca versione o real) e
# preencha com um Personal Access Token de verdade.
#
# Usado pelo Argo Workflow (argoworkflows-irsa.tf/argoworkflows-template.tf)
# para dar "git push" da atualização de apps/springboot/values.yaml de volta
# no repositório, depois do build+push da imagem no ECR.
#
# Crie o token em https://github.com/settings/tokens com escopo "repo"
# (classic) ou "Contents: Read and write" (fine-grained, escopado só ao
# repositório usado em github_repo_url).
#
# Depois, inclua este arquivo também no apply da camada platform:
#   terraform apply \
#     -var-file=environment/dev/terraform.tfvars \
#     -var-file=environment/dev/secrets.tfvars
#
# Se o token vazar, revogue-o imediatamente em
# https://github.com/settings/tokens e gere um novo.

github_username = "rodrigofrs13"
github_token     = "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"
