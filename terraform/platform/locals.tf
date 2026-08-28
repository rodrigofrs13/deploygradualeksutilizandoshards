# Aproxima "no máximo N EC2 por nodepool" via limits.cpu/memory (Karpenter não tem campo nativo de contagem). Ver README, "Isolamento físico das
# shards". Ao adicionar um tipo de instância novo em var.shard_instance_types, inclua as specs dele aqui também.
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

  # Deduz o nome da IAM role dos nodes a partir de var.cluster_name (padrão criado por terraform/infra/iam.tf), em vez de exigir que o mesmo nome
  # seja digitado de novo em var.node_role_name. Só usa var.node_role_name se alguém explicitamente sobrescrever esse padrão.
  node_role_name = coalesce(var.node_role_name, "${var.cluster_name}-node-role")
}
