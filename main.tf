resource "aws_eks_cluster" "main" {
  name     = local.resource_name
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = var.cluster_security_group_ids
  }

  access_config {
    authentication_mode = "API"
    # Grants admin to the IAM identity that runs terraform apply
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags = merge(local.common_tags, { Name = local.resource_name }, var.cluster_tags)

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# One launch template per active node group
resource "aws_launch_template" "node" {
  for_each = local.active_node_groups

  name                   = "${local.resource_name}-${each.key}-lt"
  vpc_security_group_ids = var.node_security_group_ids

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = each.value.disk_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  # Tags applied to the EC2 instances (nodes) themselves
  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      {
        Name      = "${local.resource_name}-${each.key}-node"
        NodeGroup = each.key
      }
    )
  }

  # Tags applied to the root EBS volumes of each node
  tag_specifications {
    resource_type = "volume"
    tags = merge(
      local.common_tags,
      {
        Name      = "${local.resource_name}-${each.key}-volume"
        NodeGroup = each.key
      }
    )
  }

  tags = merge(local.common_tags, { Name = "${local.resource_name}-${each.key}-lt" })
}

# One node group per active entry — blue/green controlled by create flag in consumer
resource "aws_eks_node_group" "main" {
  for_each = local.active_node_groups

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.resource_name}-${each.key}"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  ami_type        = each.value.ami_type
  instance_types  = each.value.instance_types
  capacity_type   = each.value.capacity_type
  version         = each.value.kubernetes_version != "" ? each.value.kubernetes_version : var.cluster_version

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = each.value.labels

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(local.common_tags, { Name = "${local.resource_name}-${each.key}" })

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]
}
