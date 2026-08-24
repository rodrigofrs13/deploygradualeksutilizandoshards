# StorageClass para o EBS via EKS Auto Mode.
#
# Diferente do que o nome "block storage" sugere, o Auto Mode NÃO cria
# nenhuma StorageClass automaticamente — a documentação da AWS é explícita
# sobre isso (https://docs.aws.amazon.com/eks/latest/userguide/sample-storage-workload.html):
# "EKS Auto Mode does not create a StorageClass for you. You must create a
# StorageClass referencing ebs.csi.eks.amazonaws.com".
#
# O detalhe importante (e a causa de um PVC ficar preso pra sempre em
# Pending com "Waiting for a volume to be created by the external
# provisioner 'ebs.csi.aws.com'"): o provisioner do Auto Mode tem um nome
# DIFERENTE do driver EBS CSI padrão — "ebs.csi.eks.amazonaws.com" (com
# "eks" no meio), não "ebs.csi.aws.com". A StorageClass "gp2" que já vem
# com todo cluster EKS usa o provisioner legado "kubernetes.io/aws-ebs",
# que via CSI migration aponta para "ebs.csi.aws.com" — um driver que
# simplesmente não roda no Auto Mode (o driver dele é 100% gerenciado pela
# AWS, sem nenhum pod visível em kube-system). Por isso o volume nunca é
# provisionado: não existe componente nenhum escutando esse provisioner.
resource "kubectl_manifest" "storageclass_auto_ebs" {
  yaml_body = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: auto-ebs-sc
      annotations:
        storageclass.kubernetes.io/is-default-class: "true"
    provisioner: ebs.csi.eks.amazonaws.com
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      type: gp3
      encrypted: "true"
  YAML

  depends_on = [time_sleep.wait_for_eks]
}
