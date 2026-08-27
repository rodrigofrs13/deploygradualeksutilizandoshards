#!/usr/bin/env bash
set -euo pipefail

# 03-list-nlbs.sh
#
# Lista todos os Network Load Balancers (NLBs) relevantes para este projeto:
#   1) os Services do tipo LoadBalancer no cluster (ArgoCD, Argo Workflows,
#      e o `springboot-stable` de cada shard — ver README, seções "Expondo
#      ... via LoadBalancer"), com o hostname atribuído por cada um;
#   2) os NLBs correspondentes na conta/região AWS (nome, scheme, estado,
#      DNS name), via AWS ELBv2.
#
# Uso:
#   ./scripts/03-list-nlbs.sh [regiao-aws]
#
#   Se nenhuma região for passada, usa $AWS_REGION ou "us-east-1" (mesmo
#   default de environment/dev/terraform.tfvars).
#
# Requisitos: kubectl já configurado (aws eks update-kubeconfig ...),
# AWS CLI autenticada, jq no PATH.
# (Se no seu ambiente o binário de jq estiver com outro nome, ex.
# jq-windows-amd64.exe, ajuste a variável JQ_BIN abaixo ou crie um alias.)

AWS_REGION="${1:-${AWS_REGION:-us-east-1}}"
JQ_BIN="${JQ_BIN:-jq-windows-amd64.exe}"

for bin in kubectl aws "$JQ_BIN"; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Erro: '$bin' não encontrado no PATH." >&2
    exit 1
  }
done

echo "== Services do tipo LoadBalancer no cluster =="
printf "%-15s %-20s %-55s %s\n" "NAMESPACE" "SERVICE" "HOSTNAME" "PORTAS"

kubectl get svc --all-namespaces -o json \
  | "$JQ_BIN" -r '
      .items[]
      | select(.spec.type == "LoadBalancer")
      | [
          .metadata.namespace,
          .metadata.name,
          (.status.loadBalancer.ingress[0].hostname // "<pendente>"),
          ([.spec.ports[] | "\(.port)->\(.targetPort)/\(.protocol)"] | join(","))
        ]
      | @tsv
    ' \
  | while IFS=$'\t' read -r ns name host ports; do
      printf "%-15s %-20s %-55s %s\n" "$ns" "$name" "$host" "$ports"
    done

echo
echo "== Network Load Balancers na AWS (região: $AWS_REGION) =="
printf "%-45s %-12s %-10s %s\n" "NOME" "SCHEME" "STATE" "DNS NAME"

aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?Type=='network']" --output json \
  | "$JQ_BIN" -r '.[] | [.LoadBalancerName, .Scheme, .State.Code, .DNSName] | @tsv' \
  | while IFS=$'\t' read -r name scheme state dns; do
      printf "%-45s %-12s %-10s %s\n" "$name" "$scheme" "$state" "$dns"
    done

echo
echo "Dica: o provisionamento do NLB é assíncrono (EKS Auto Mode) — um"
echo "hostname \"<pendente>\" no Service, ou a ausência do NLB na lista da"
echo "AWS, costuma se resolver em 1-2 min após o 'terraform apply'/sync."
