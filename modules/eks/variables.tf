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
