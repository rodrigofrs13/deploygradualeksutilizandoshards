# NodePool (karpenter.sh/v1): Spot+on-demand, tipos em var.shard_instance_types, limits.cpu/memory aproximando var.shard_max_nodes (locals.tf), e
# o taint "shard=<nome>:NoSchedule" que isola fisicamente cada shard. Ver README, "Isolamento físico das shards".
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
