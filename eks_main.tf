###############################################################################
# Root configuration - EKS cluster.
#
# Region is fixed. `var.environment` selects a local config set. VPC networking
# is read from the fdp-infra-networking repo's remote state in the shared S3
# state bucket.
#
#   prefix = "<app_name>-<env_name>-<region_short_name>"   e.g. fdp-dev-euw2
###############################################################################

variable "environment" {
  description = "Which local config set to deploy. One of: dev, prod."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be either \"dev\" or \"prod\"."
  }
}

locals {
  app_name = "fdp"
  region   = "eu-west-2" # London

  region_short_names = {
    "eu-west-2" = "euw2"
    "eu-west-1" = "euw1"
    "us-east-1" = "use1"
  }
  region_short = local.region_short_names[local.region]

  # ---- Per-environment config sets (identical keys in both) -------------- #
  env_configs = {
    dev = {
      env_name           = "dev"
      kubernetes_version = "1.31"

      endpoint_public_access = true
      public_access_cidrs    = ["0.0.0.0/0"] # dev: public endpoint open

      node_groups = {
        general = {
          instance_types = ["t3.medium"]
          capacity_type  = "ON_DEMAND"
          desired_size   = 2
          min_size       = 2
          max_size       = 4
          disk_size      = 50
        }
      }
    }

    prod = {
      env_name           = "prod"
      kubernetes_version = "1.31"

      endpoint_public_access = true
      # prod: lock the public API endpoint to office / VPN egress ranges.
      #public_access_cidrs = ["REPLACE-vpn-or-office-cidr/32"]
      public_access_cidrs = ["10.0.0.0/20"]

      node_groups = {
        general = {
          instance_types = ["t3.large"]
          capacity_type  = "ON_DEMAND"
          desired_size   = 3
          min_size       = 3
          max_size       = 6
          disk_size      = 50
        }
      }
    }
  }

  env    = local.env_configs[var.environment]
  prefix = "${local.app_name}-${local.env.env_name}-${local.region_short}"

  common_tags = {
    Application = local.app_name
    Environment = local.env.env_name
    Region      = local.region
    ManagedBy   = "terraform"
    Repository  = "fdp-infra-compute"
  }

  # Extra EKS access entries (no aws-auth ConfigMap). The dedicated cluster-admin
  # role is created by the module and wired up automatically - add entries here
  # only for additional principals: { "<principal-arn>" = ["<policy-arn>", ...] }.
  access_entries = {}
}

# Principal ARNs allowed to assume the dedicated cluster-admin role the module
# creates. Leave empty to trust the account root (any principal in the account
# whose IAM policy permits sts:AssumeRole on the role); set it to specific IAM
# user / SSO role ARNs to lock it down.
variable "eks_admin_trusted_principals" {
  description = "Principal ARNs allowed to assume the EKS cluster-admin role. Empty => account root."
  type        = list(string)
  default     = []
}

provider "aws" {
  region = local.region

  default_tags {
    tags = local.common_tags
  }
}

###############################################################################
# VPC networking from the fdp-infra-networking repo's remote state.
#
# Requires fdp-infra-networking to have been applied for this environment first
# (its state must exist at fdp-infra-networking/<env>/terraform.tfstate in the
# shared bucket).
###############################################################################

data "terraform_remote_state" "vpc" {
  backend = "s3"

  config = {
    bucket = "fdp-infra-state-bucket-861477414666-eu-west-2-an"
    key    = "fdp-infra-networking/${var.environment}/terraform.tfstate"
    region = local.region
  }
}

###############################################################################
# EKS
###############################################################################

module "eks" {
  source = "./modules/eks"

  prefix             = local.prefix
  kubernetes_version = local.env.kubernetes_version

  vpc_id     = data.terraform_remote_state.vpc.outputs.vpc_id
  subnet_ids = data.terraform_remote_state.vpc.outputs.private_app_subnet_ids

  additional_cluster_security_group_ids = [
    data.terraform_remote_state.vpc.outputs.eks_security_group_id,
  ]

  endpoint_public_access = local.env.endpoint_public_access
  public_access_cidrs    = local.env.public_access_cidrs

  node_groups    = local.env.node_groups
  access_entries = local.access_entries

  create_admin_role             = true
  admin_role_trusted_principals = var.eks_admin_trusted_principals

  tags = local.common_tags
}
