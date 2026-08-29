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

output "aws_region" {
  description = "AWS region the cluster and load balancers run in."
  value       = local.region
}

# --- AWS Load Balancer Controller / internal ALB --------------------- #
output "alb_controller_role_arn" {
  description = "IRSA role ARN assumed by the AWS Load Balancer Controller."
  value       = module.eks.alb_controller_role_arn
}

output "alb_ingress_class_name" {
  description = "IngressClass name the application repo sets to get an internal ALB (e.g. \"alb\")."
  value       = module.eks.alb_ingress_class_name
}

output "alb_security_group_id" {
  description = <<-EOT
    Frontend security group for the internal ALBs. The application repo attaches
    it to the Fraud Service Ingress via
    `alb.ingress.kubernetes.io/security-groups`; reuse it as the API Gateway
    VPC Link security group downstream.
  EOT
  value       = module.eks.alb_security_group_id
}

# VPC Link (API Gateway HTTP API) prerequisites. The ALB listener ARN itself is
# created by the application repo's Ingress and read at runtime with
# `kubectl get ingress` / the ELBv2 API - it is not known to this repo.
output "vpc_id" {
  description = "VPC ID (for API Gateway VPC Link and other downstream consumers)."
  value       = data.terraform_remote_state.vpc.outputs.vpc_id
}

output "private_app_subnet_ids" {
  description = "Private application subnet IDs the internal ALB and a VPC Link attach to."
  value       = data.terraform_remote_state.vpc.outputs.private_app_subnet_ids
}
