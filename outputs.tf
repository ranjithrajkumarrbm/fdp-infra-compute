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
  description = "IngressClass name available for Ingress-driven ALBs (e.g. \"alb\"). The Fraud Service uses the target group below instead."
  value       = module.eks.alb_ingress_class_name
}

output "alb_security_group_id" {
  description = <<-EOT
    Frontend security group attached to the internal ALB. Reuse it as the
    API Gateway VPC Link security group downstream.
  EOT
  value       = module.eks.alb_security_group_id
}

# --- Internal ALB (created here) ------------------------------------- #
output "alb_arn" {
  description = "ARN of the internal ALB."
  value       = module.eks.alb_arn
}

output "alb_dns_name" {
  description = "DNS name of the internal ALB (resolvable only inside the VPC)."
  value       = module.eks.alb_dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID of the internal ALB, for Route 53 alias records."
  value       = module.eks.alb_zone_id
}

output "alb_listener_arn" {
  description = "Listener ARN for the API Gateway HTTP API VPC Link integration (HTTPS:443 if a cert is set, else HTTP:80)."
  value       = module.eks.alb_listener_arn
}

output "alb_target_group_arn" {
  description = "Target group ARN the application repo binds Fraud Service pods to with a TargetGroupBinding (no Ingress required)."
  value       = module.eks.alb_target_group_arn
}

# VPC Link (API Gateway HTTP API) prerequisites.
output "vpc_id" {
  description = "VPC ID (for API Gateway VPC Link and other downstream consumers)."
  value       = data.terraform_remote_state.vpc.outputs.vpc_id
}

output "private_app_subnet_ids" {
  description = "Private application subnet IDs the internal ALB and a VPC Link attach to."
  value       = data.terraform_remote_state.vpc.outputs.private_app_subnet_ids
}
