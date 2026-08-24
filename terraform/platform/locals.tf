# O Karpenter (base do EKS Auto Mode) não possui um campo nativo para
# "número máximo de nodes" em um NodePool — os limites em spec.limits são
# sempre baseados em soma de recursos (cpu/memory) do cluster provisionado
# por aquele NodePool, não em contagem de instâncias.
#
# Para aproximar "no máximo N EC2 por nodepool", permitimos um pequeno
# conjunto de tipos de instância equivalentes em var.shard_instance_types
# (dar mais de uma opção reduz o risco de falha por falta de capacidade
# Spot de um único tipo) e calculamos o limite de CPU/memória com base no
# MAIOR tipo do conjunto — isso garante que, em qualquer combinação de
# tipos que o Karpenter escolher, o teto de var.shard_max_nodes nunca seja
# ultrapassado (no pior caso, ele preenche só com o tipo maior).
#
# Se adicionar um tipo novo a var.shard_instance_types, inclua as specs
# dele no mapa abaixo.
locals {
  instance_specs = {
    "m5.large"   = { vcpu = 2, memory_gib = 8 }
    "m5a.large"  = { vcpu = 2, memory_gib = 8 }
    "m5.xlarge"  = { vcpu = 4, memory_gib = 16 }
    "m5a.xlarge" = { vcpu = 4, memory_gib = 16 }
    "m6i.large"  = { vcpu = 2, memory_gib = 8 }
    "c5.large"   = { vcpu = 2, memory_gib = 4 }
    "c5a.large"  = { vcpu = 2, memory_gib = 4 }
  }

  shard_max_vcpu_per_instance       = max([for t in var.shard_instance_types : local.instance_specs[t].vcpu]...)
  shard_max_memory_gib_per_instance = max([for t in var.shard_instance_types : local.instance_specs[t].memory_gib]...)

  shard_vcpu_limit   = local.shard_max_vcpu_per_instance * var.shard_max_nodes
  shard_memory_limit = "${local.shard_max_memory_gib_per_instance * var.shard_max_nodes}Gi"
}

