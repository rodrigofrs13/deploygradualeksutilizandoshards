# NodePool define as regras de scheduling/capacidade (karpenter.sh/v1).
# Ambos os shards usam:
#   - Spot com fallback on-demand (karpenter.sh/capacity-type in [spot, ondemand])
#   - um pequeno conjunto de tipos de instância equivalentes
#     (var.shard_instance_types), para dar mais chance ao Spot e ainda
#     assim permitir aproximar "máximo N EC2" via limits.cpu/memory
#     (ver locals.tf)
#   - AMI Bottlerocket, que é a única disponível no EKS Auto Mode (definida
#     implicitamente pelo NodeClass referenciado)
#   - um taint "shard=<nome>:NoSchedule" — é isso que isola FISICAMENTE cada
#     shard: só pods com a toleration correspondente (já definida no
#     Rollout, apps/springboot/templates/rollout.yaml) conseguem agendar
#     nesses nodes. Sem o taint, o label "shard" no nodeSelector garante que
#     o pod vá PARA lá, mas não impede outros pods (sem esse nodeSelector)
#     de também caírem nesses nodes.

resource "kubectl_manifest" "nodepool_shard_1" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: node-pool-shard-1
    spec:
      template:
        metadata:
          labels:
            shard: shard-1
        spec:
          nodeClassRef:
            group: eks.amazonaws.com
            kind: NodeClass
            name: node-pool-shard-1
          requirements:
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot","ondemand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ${jsonencode(var.shard_instance_types)}
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
          taints:
            - key: shard
              value: shard-1
              effect: NoSchedule
      limits:
        cpu: "${local.shard_vcpu_limit}"
        memory: "${local.shard_memory_limit}"
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [kubectl_manifest.nodeclass_shard_1]
}

resource "kubectl_manifest" "nodepool_shard_2" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: node-pool-shard-2
    spec:
      template:
        metadata:
          labels:
            shard: shard-2
        spec:
          nodeClassRef:
            group: eks.amazonaws.com
            kind: NodeClass
            name: node-pool-shard-2
          requirements:
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot","ondemand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ${jsonencode(var.shard_instance_types)}
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
          taints:
            - key: shard
              value: shard-2
              effect: NoSchedule
      limits:
        cpu: "${local.shard_vcpu_limit}"
        memory: "${local.shard_memory_limit}"
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
  YAML

  depends_on = [kubectl_manifest.nodeclass_shard_2]
}
