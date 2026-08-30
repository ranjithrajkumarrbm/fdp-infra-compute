variable "prefix" {
  description = "Prefix applied to the name of every resource, e.g. \"fdp-dev-euw2\"."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name. Defaults to \"<prefix>-eks\" when left empty."
  type        = string
  default     = ""
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane, e.g. \"1.31\"."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC the cluster runs in (from the VPC repo's remote state)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the control-plane ENIs and worker nodes - the private application subnets."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Provide at least two subnets in different AZs."
  }
}

variable "additional_cluster_security_group_ids" {
  description = "Extra security group IDs to attach to the cluster (e.g. the VPC repo's shared EKS SG)."
  type        = list(string)
  default     = []
}

variable "endpoint_private_access" {
  description = "Enable the private Kubernetes API endpoint."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Enable the public Kubernetes API endpoint."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Lock this down outside dev."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_cluster_log_types" {
  description = "Control-plane log types to ship to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "cluster_log_retention_days" {
  description = "Retention for the control-plane CloudWatch log group."
  type        = number
  default     = 90
}

variable "node_groups" {
  description = "Managed node groups, keyed by name."
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    desired_size   = number
    min_size       = number
    max_size       = number
    disk_size      = optional(number, 50)
    ami_type       = optional(string, "AL2023_x86_64_STANDARD")
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string # NO_SCHEDULE | PREFER_NO_SCHEDULE | NO_EXECUTE
    })), [])
  }))
}

variable "addons" {
  description = "EKS managed addons: name => version. Use null for the EKS-default version."
  type        = map(string)
  default = {
    vpc-cni    = null
    coredns    = null
    kube-proxy = null
  }
}

variable "access_entries" {
  description = "EKS access entries: principal ARN => list of access policy ARNs to associate (cluster-wide)."
  type        = map(list(string))
  default     = {}
}

variable "create_admin_role" {
  description = "Create a dedicated IAM role wired to the AmazonEKSClusterAdminPolicy access entry."
  type        = bool
  default     = true
}

variable "admin_role_trusted_principals" {
  description = "Principal ARNs allowed to assume the dedicated admin role. Empty => the account root."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}

# --- AWS Load Balancer Controller ------------------------------------- #
variable "region" {
  description = "AWS region the cluster runs in (used by the AWS Load Balancer Controller)."
  type        = string
}

variable "enable_alb_controller" {
  description = "Install the AWS Load Balancer Controller (IRSA role + IAM policy + Helm release + internal-ALB security group)."
  type        = bool
  default     = true
}

variable "alb_controller_chart_version" {
  description = "Version of the aws-load-balancer-controller Helm chart (https://aws.github.io/eks-charts)."
  type        = string
  default     = "1.13.3"
}

variable "alb_allowed_cidrs" {
  description = "CIDRs allowed to reach the internal ALB frontend security group. Empty => the VPC CIDR."
  type        = list(string)
  default     = []
}

variable "alb_listener_ports" {
  description = "TCP ports opened on the internal ALB frontend security group for clients."
  type        = list(number)
  default     = [80, 443]
}

variable "create_internal_alb" {
  description = "Create a concrete internal ALB + listener(s) + target group in this repo (requires enable_alb_controller)."
  type        = bool
  default     = true
}

variable "alb_target_port" {
  description = "Container port the internal ALB target group forwards to (the application pod port)."
  type        = number
  default     = 8080
}

variable "alb_health_check_path" {
  description = "HTTP health-check path for the internal ALB target group (expects HTTP 200)."
  type        = string
  default     = "/actuator/health/readiness"
}

variable "alb_certificate_arn" {
  description = "ACM certificate ARN for an HTTPS:443 listener on the internal ALB. Empty => HTTP:80 only."
  type        = string
  default     = ""
}
