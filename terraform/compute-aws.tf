resource "aws_key_pair" "ssh_key" {
  provider   = aws.compute
  key_name   = "kp-suse-observability"
  public_key = var.ssh_public_key != null ? var.ssh_public_key : file("~/.ssh/id_rsa.pub")
}

# Auto-discover the latest SLES 15 SP7 BYOS AMI published by aws_sles_ami_owner_id
# unless aws_ami_id overrides it. Must be the BYOS (Bring Your Own Subscription)
# image, not the plain/PAYG one: the boot script registers with SCC itself via
# `SUSEConnect -r var.sles_reg_code`, and doing that against a PAYG image - which
# auto-registers against SUSE's own update infrastructure at launch - creates
# registration conflicts. See cloud-rancher's compute-aws.tf for how the owner ID
# and name filter below were verified against `aws ec2 describe-images`.
data "aws_ami" "sles" {
  count = var.aws_ami_id == "" ? 1 : 0

  provider    = aws.compute
  most_recent = true
  owners      = [var.aws_sles_ami_owner_id]

  filter {
    name   = "name"
    values = ["suse-sles-15-sp7-byos-v????????-hvm-ssd-x86_64-prod-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  aws_ami_id = var.aws_ami_id != "" ? var.aws_ami_id : data.aws_ami.sles[0].id
}

resource "aws_eip" "cluster_node_eip" {
  count = var.cluster_node_count

  provider = aws.compute
  domain   = "vpc"

  tags = {
    Name = "eip-observability-node-${count.index + 1}"
  }
}

# A dedicated NIC per node, purely so join-node instances can read node 0's
# private IP (for "server: https://<ip>:9345" in their RKE2 config) from a
# resource other than aws_instance.cluster_vm itself: referencing
# aws_instance.cluster_vm[0] from within aws_instance.cluster_vm's own
# user_data is a self-referential block, which Terraform rejects even though
# count.index == 0 makes it reachable only for the one instance that isn't
# self-referencing.
resource "aws_network_interface" "cluster_nic" {
  count = var.cluster_node_count

  provider        = aws.compute
  subnet_id       = aws_subnet.subnet.id
  security_groups = [aws_security_group.nsg.id]

  tags = {
    Name = "nic-observability-node-${count.index + 1}"
  }
}

resource "aws_instance" "cluster_vm" {
  count = var.cluster_node_count

  provider             = aws.compute
  ami                  = local.aws_ami_id
  instance_type        = var.aws_instance_type
  key_name             = aws_key_pair.ssh_key.key_name
  iam_instance_profile = aws_iam_instance_profile.ebs_csi.name

  network_interface {
    network_interface_id = aws_network_interface.cluster_nic[count.index].id
    device_index         = 0
  }

  # The first node's boot script requests a Let's Encrypt certificate via
  # HTTP-01 against suse_observability_hostname, which needs the Route53
  # record (if any) to exist first.
  depends_on = [aws_route53_record.observability_dns]

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = {
    Name = "vm-observability-node-${count.index + 1}"
  }

  # Gzipped rather than plain base64: the rendered script (especially with
  # custom TLS certs/CA embedded, not Let's Encrypt) can exceed AWS's 25600-byte
  # encoded user-data limit otherwise. EC2's cloud-init auto-detects gzip and
  # decompresses it before running, so this is transparent at boot.
  user_data_base64 = base64gzip(
    count.index == 0 ?
    templatefile("${path.module}/templates/first-node.sh.tpl", {
      vm_hostname                       = "vm-observability-node-${count.index + 1}",
      sles_reg_code                     = var.sles_reg_code,
      rke2_token                        = var.rke2_token,
      lb_ip                             = local.lb_public_ip,
      observability_hostname            = local.observability_hostname,
      suse_observability_license        = var.suse_observability_license,
      suse_observability_admin_password = var.suse_observability_admin_password,
      suse_observability_sizing_profile = var.suse_observability_sizing_profile,
      suse_observability_chart_version  = var.suse_observability_chart_version,
      letsencrypt_email                 = var.letsencrypt_email,
      use_letsencrypt                   = var.use_letsencrypt,
      tls_cert_b64                      = local.tls_cert_b64,
      tls_key_b64                       = local.tls_key_b64,
      rke2_version                      = var.rke2_version,
      rke2_ingress_controller           = local.rke2_ingress_controller,
      ingress_daemonset_name            = local.ingress_daemonset_name,
      ingress_class_name                = local.ingress_class_name,
      cert_manager_version              = var.cert_manager_version
    }) :
    templatefile("${path.module}/templates/join-node.sh.tpl", {
      vm_hostname            = "vm-observability-node-${count.index + 1}",
      sles_reg_code          = var.sles_reg_code,
      rke2_token             = var.rke2_token,
      rke2_version           = var.rke2_version,
      lb_ip                  = local.lb_public_ip,
      first_node_ip          = aws_network_interface.cluster_nic[0].private_ip,
      observability_hostname = local.observability_hostname
    })
  )
}

resource "aws_eip_association" "cluster_node_eip_assoc" {
  count = var.cluster_node_count

  provider      = aws.compute
  instance_id   = aws_instance.cluster_vm[count.index].id
  allocation_id = aws_eip.cluster_node_eip[count.index].id
}

resource "aws_lb_target_group_attachment" "cluster_tg_6443" {
  count = var.cluster_node_count

  provider         = aws.compute
  target_group_arn = aws_lb_target_group.tg_6443.arn
  target_id        = aws_instance.cluster_vm[count.index].id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "cluster_tg_80" {
  count = var.cluster_node_count

  provider         = aws.compute
  target_group_arn = aws_lb_target_group.tg_80.arn
  target_id        = aws_instance.cluster_vm[count.index].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "cluster_tg_443" {
  count = var.cluster_node_count

  provider         = aws.compute
  target_group_arn = aws_lb_target_group.tg_443.arn
  target_id        = aws_instance.cluster_vm[count.index].id
  port             = 443
}
