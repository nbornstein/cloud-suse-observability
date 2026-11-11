# Unlike cloud-rancher, this project needs a working dynamic StorageClass: SUSE
# Observability's own PVCs (OpenSearch, ClickHouse, Kafka, etc.) need somewhere
# to provision volumes, and plain RKE2 (outside EKS) ships no default
# StorageClass or CSI driver. first-node.sh.tpl installs the upstream AWS EBS
# CSI driver to fill that gap - since these are plain EC2 instances rather than
# EKS-managed nodes, there's no OIDC/IRSA to grant it scoped credentials via, so
# it authenticates the same way any other process on the instance would: via an
# instance profile, using AWS's own managed policy for exactly this driver.
resource "aws_iam_role" "ebs_csi" {
  provider = aws.compute
  name     = "suse-observability-ebs-csi-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  provider   = aws.compute
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_instance_profile" "ebs_csi" {
  provider = aws.compute
  name     = "suse-observability-ebs-csi-node"
  role     = aws_iam_role.ebs_csi.name
}
