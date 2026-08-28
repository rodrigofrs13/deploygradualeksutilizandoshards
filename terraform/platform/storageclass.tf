# StorageClass do EBS para o Auto Mode — ele não cria uma sozinho, e usa um provisioner próprio (ebs.csi.eks.amazonaws.com, diferente do
# ebs.csi.aws.com clássico). Ver README, "Notas / problemas conhecidos".
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
