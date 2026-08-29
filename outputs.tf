output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA cert for kubeconfig."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes control-plane version."
  value       = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group ID."
  value       = module.eks.cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN for IRSA."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "Cluster OIDC issuer URL (no https://)."
  value       = module.eks.oidc_provider_url
}

output "node_iam_role_arn" {
  description = "ARN of the shared managed node group IAM role."
  value       = module.eks.node_iam_role_arn
}

output "eks_admin_role_arn" {
  description = "ARN of the dedicated cluster-admin role. Assume this, then run the kubeconfig command."
  value       = module.eks.admin_role_arn
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}"
}

output "resource_prefix" {
  description = "Prefix applied to all resource names."
  value       = local.prefix
}
