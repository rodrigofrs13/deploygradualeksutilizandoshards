#!/usr/bin/env bash
set -euo pipefail

# 04-delete-ecr-images.sh
#
# Apaga TODAS as imagens do repositório ECR do projeto. Útil antes do
# passo 15 (encerrar o teste / terraform destroy) de TESTE-END-TO-END.md:
# como o repositório ECR é criado com `image_tag_mutability = IMMUTABLE`
# e sem `force_delete` (ver terraform/infra/ecr.tf), o `terraform destroy`
# da camada `infra` falha se ainda houver imagens dentro do repositório
# ("RepositoryNotEmptyException") — este script esvazia o repositório
# antes, sem precisar apagar o repositório em si (o destroy cuida disso).
#
# Uso:
#   ./scripts/04-delete-ecr-images.sh [repo-name] [regiao-aws] [-y|--yes]
#
#   repo-name   default: $ECR_REPOSITORY ou "eks-automode-app-dev"
#   regiao-aws  default: $AWS_REGION ou "us-east-1"
#   -y / --yes  pula a confirmação interativa (para uso em automação)
#
# Requisitos: AWS CLI autenticada com permissão ecr:ListImages /
# ecr:BatchDeleteImage / ecr:DescribeRepositories, jq no PATH.

ECR_REPOSITORY="${1:-${ECR_REPOSITORY:-eks-automode-app-dev}}"
AWS_REGION="${2:-${AWS_REGION:-us-east-1}}"
AUTO_YES="false"

for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES="true" ;;
  esac
done

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Erro: '$bin' não encontrado no PATH." >&2
    exit 1
  }
done

echo "Repositório: $ECR_REPOSITORY (região: $AWS_REGION)"

if ! aws ecr describe-repositories \
      --repository-names "$ECR_REPOSITORY" \
      --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Repositório '$ECR_REPOSITORY' não encontrado em $AWS_REGION — nada a fazer." >&2
  exit 1
fi

IMAGE_IDS_JSON=$(
  aws ecr list-images \
    --repository-name "$ECR_REPOSITORY" \
    --region "$AWS_REGION" \
    --query 'imageIds' \
    --output json
)

TOTAL=$(echo "$IMAGE_IDS_JSON" | jq 'length')

if [ "$TOTAL" -eq 0 ]; then
  echo "Repositório já está vazio — nada a apagar."
  exit 0
fi

echo
echo "Imagens encontradas ($TOTAL):"
echo "$IMAGE_IDS_JSON" \
  | jq -r '.[] | "  - \(.imageTag // "<untagged>")  \(.imageDigest)"'
echo

if [ "$AUTO_YES" != "true" ]; then
  read -r -p "Apagar TODAS as $TOTAL imagens acima de '$ECR_REPOSITORY'? Esta ação não pode ser desfeita. Digite 'yes' para confirmar: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelado — nenhuma imagem foi apagada."
    exit 1
  fi
fi

# A API batch-delete-image aceita no máximo 100 imageIds por chamada —
# divide em lotes com jq puro (fatiamento de array, sem depender de
# filtros custom como _nwise).
BATCH_SIZE=100
COUNT=0
while : ; do
  BATCH=$(echo "$IMAGE_IDS_JSON" | jq -c ".[$COUNT:$((COUNT + BATCH_SIZE))]")
  BATCH_LEN=$(echo "$BATCH" | jq 'length')
  [ "$BATCH_LEN" -eq 0 ] && break

  aws ecr batch-delete-image \
    --repository-name "$ECR_REPOSITORY" \
    --region "$AWS_REGION" \
    --image-ids "$BATCH" \
    --output json \
    | jq -r '
        (.imageIds // [] | length) as $ok
        | (.failures // [] | length) as $fail
        | "  lote: \($ok) apagada(s), \($fail) falha(s)"
      '

  COUNT=$((COUNT + BATCH_SIZE))
done

echo
echo "Concluído. Revalidando repositório..."
REMAINING=$(
  aws ecr list-images \
    --repository-name "$ECR_REPOSITORY" \
    --region "$AWS_REGION" \
    --query 'length(imageIds)' \
    --output text
)
echo "Imagens restantes em '$ECR_REPOSITORY': $REMAINING"

if [ "$REMAINING" != "0" ]; then
  echo "Aviso: ainda restam imagens (podem ter sido protegidas por lifecycle policy" >&2
  echo "ou por outra tag/manifest associado) — verifique antes do 'terraform destroy'." >&2
  exit 1
fi
