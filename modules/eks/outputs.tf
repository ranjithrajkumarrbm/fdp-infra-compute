output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  description = "Endpoint for the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA cert for the cluster (for kubeconfig)."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "The EKS-managed cluster security group ID."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider (for IRSA trust policies)."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "URL of the cluster OIDC issuer (without https://)."
  value       = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

output "node_iam_role_arn" {
  description = "ARN of the shared managed node group IAM role."
  value       = aws_iam_role.node.arn
}

output "admin_role_arn" {
  description = "ARN of the dedicated cluster-admin role (null when create_admin_role = false)."
  value       = var.create_admin_role ? aws_iam_role.admin[0].arn : null
}

output "node_group_names" {
  description = "Names of the managed node groups."
  value       = [for ng in aws_eks_node_group.this : ng.node_group_name]
}

# --- AWS Load Balancer Controller ------------------------------------- #
output "alb_controller_role_arn" {
  description = "IRSA role ARN assumed by the AWS Load Balancer Controller (null when disabled)."
  value       = local.alb_controller_enabled ? aws_iam_role.alb_controller[0].arn : null
}

output "alb_controller_iam_policy_arn" {
  description = "ARN of the AWS Load Balancer Controller IAM policy (null when disabled)."
  value       = local.alb_controller_enabled ? aws_iam_policy.alb_controller[0].arn : null
}

output "alb_security_group_id" {
  description = "Frontend security group ID for the internal ALBs. Attach to Ingresses and reuse for API Gateway VPC Link."
  value       = local.alb_controller_enabled ? aws_security_group.alb[0].id : null
}

output "alb_ingress_class_name" {
  description = "IngressClass name that provisions an internal ALB (empty when disabled)."
  value       = local.alb_controller_enabled ? "alb" : ""
}
