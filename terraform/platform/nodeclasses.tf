# NodeClass define a infraestrutura AWS usada pelos nodes (role, subnets,
# security groups). No EKS Auto Mode, a AMI é sempre a Bottlerocket
# gerenciada pela AWS — não existe campo para escolher outra AMI/family.

resource "kubectl_manifest" "nodeclass_shard_1" {
  yaml_body = <<-YAML
    apiVersion: eks.amazonaws.com/v1
    kind: NodeClass
    metadata:
      name: node-pool-shard-1
    spec:
      role: ${var.node_role_name}
      subnetSelectorTerms:
        - tags:
            kubernetes.io/role/internal-elb: "1"
      securityGroupSelectorTerms:
        - tags:
            aws:eks:cluster-name: ${var.cluster_name}
  YAML

  depends_on = [data.aws_eks_cluster.this]
}

resource "kubectl_manifest" "nodeclass_shard_2" {
  yaml_body = <<-YAML
    apiVersion: eks.amazonaws.com/v1
    kind: NodeClass
    metadata:
      name: node-pool-shard-2
    spec:
      role: ${var.node_role_name}
      subnetSelectorTerms:
        - tags:
            kubernetes.io/role/internal-elb: "1"
      securityGroupSelectorTerms:
        - tags:
            aws:eks:cluster-name: ${var.cluster_name}
  YAML

  depends_on = [data.aws_eks_cluster.this]
}
