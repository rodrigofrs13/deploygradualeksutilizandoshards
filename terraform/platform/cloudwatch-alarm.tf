# Alarme de TESTE do desafio extra (promoção automática shard-1 -> shard-2). Nenhum app publica essa métrica de verdade — force o estado
# manualmente com "aws cloudwatch set-alarm-state". Ver README, "Promoção shard-1 -> shard-2".
resource "aws_cloudwatch_metric_alarm" "springboot_shard1_health" {
  alarm_name          = "${var.cluster_name}-springboot-shard1-health"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckFailures"
  namespace           = "SpringbootCanary"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0

  # "breaching": sem dado nenhum, fica em ALARM (fail-closed) em vez de OK.
  treat_missing_data = "breaching"

  alarm_description = "Alarme de TESTE para o desafio extra de promocao automatica shard-1 -> shard-2 via Argo Workflows. Ver README para os comandos de teste."
}
