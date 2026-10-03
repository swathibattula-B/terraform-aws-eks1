output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "API server endpoint — reachable only from within the VPC (private cluster)"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded certificate authority data for the cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "ID of the cluster security group created by EKS"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster control plane"
  value       = aws_eks_cluster.main.version
}

output "node_group_ids" {
  description = "Map of node group IDs keyed by name (e.g. blue, green)"
  value       = { for k, v in aws_eks_node_group.main : k => v.id }
}

output "node_group_statuses" {
  description = "Map of node group statuses keyed by name — useful during blue-green upgrade"
  value       = { for k, v in aws_eks_node_group.main : k => v.status }
}

output "node_role_arn" {
  description = "ARN of the shared node group IAM role"
  value       = aws_iam_role.node.arn
}

output "cluster_role_arn" {
  description = "ARN of the cluster IAM role"
  value       = aws_iam_role.cluster.arn
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — pass this to any IRSA role module"
  value       = aws_iam_openid_connect_provider.main.arn
}

output "oidc_issuer" {
  description = "OIDC issuer URL without https:// prefix — used in IRSA trust policy conditions"
  value       = replace(aws_iam_openid_connect_provider.main.url, "https://", "")
}

output "admin_iam_arn" {
  description = "IAM ARN that was granted cluster admin on creation"
  value       = data.aws_caller_identity.current.arn
}
