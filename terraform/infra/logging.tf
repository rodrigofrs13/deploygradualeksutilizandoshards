# O EKS cria automaticamente um log group "/aws/eks/<cluster>/cluster" ao habilitar os logs do control plane, 
# Foi criando o log group antes, com retenção explícita, para que o cluster apenas passe a usá-lo. O Log Group default é criado mas sem retenção definida (logs nunca
# expiram, gerando custo crescente)
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days
}
