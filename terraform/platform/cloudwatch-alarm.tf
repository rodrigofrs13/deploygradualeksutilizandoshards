# Alarme do Desafio Extra: liga com o step check-cloudwatch-alarm do WorkflowTemplate (argoworkflows-template.tf), 
# usado só quando apps/springboot/values.yaml tem promotion.automaticApproval = true.
#
# Isso é um alarme de TESTE/MANUAL — não existe nenhum agente/app publicando a métrica "HealthCheckFailures" de verdade nesse desafio 
# (não há um health check externo rodando). O objetivo aqui é permitir forçar cada um dos 3 estados manualmente pra validar o fluxo automático fim a fim, com:
#
#   aws cloudwatch set-alarm-state \
#     --alarm-name eks-automode-dev-springboot-shard1-health \
#     --state-value OK \
#     --state-reason "teste manual - promocao automatica" \
#     --region us-east-1
#
# Troque --state-value por ALARM (deve disparar rollback-shard1) ou INSUFFICIENT_DATA (mesmo comportamento do ALARM — fail-closed, ver
# comentário em argoworkflows-template.tf). Sem nenhum "set-alarm-state" manual, o alarme fica em INSUFFICIENT_DATA por padrão (treat_missing_data
# abaixo), porque nunca chega dado nenhum pra métrica "SpringbootCanary/HealthCheckFailures" — ou seja, o default é sempre BLOQUEAR a promoção
# automática até alguém confirmar o estado, nunca promover "por acidente".

resource "aws_cloudwatch_metric_alarm" "springboot_shard1_health" {
  alarm_name          = "${var.cluster_name}-springboot-shard1-health"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 1
  metric_name         = "HealthCheckFailures"
  namespace           = "SpringbootCanary"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0

  # "breaching" = sem dado nenhum, o alarme fica em ALARM/INSUFFICIENT_DATA (fail-closed) em vez de OK — não queremos que a promoção automática
  # aconteça só porque ninguém publicou métrica nenhuma ainda.
  treat_missing_data = "breaching"

  alarm_description = "Alarme de TESTE para o desafio extra de promocao automatica shard-1 -> shard-2 via Argo Workflows. Forcar estado manualmente com 'aws cloudwatch set-alarm-state' (ver comentario deste arquivo) ou publicar a metrica de verdade com 'aws cloudwatch put-metric-data --namespace SpringbootCanary --metric-name HealthCheckFailures --value 0'."
}
