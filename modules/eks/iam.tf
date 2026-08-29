###############################################################################
# IAM - cluster role, node role, and the IRSA OIDC provider
###############################################################################

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  cluster_name = var.cluster_name != "" ? var.cluster_name : "${var.prefix}-eks"

  # Dedicated cluster-admin role (created here when var.create_admin_role).
  # The ARN is assembled from known values so it can be used as a for_each key
  # in aws_eks_access_entry without an apply-time "unknown key" error.
  admin_role_name = "${local.cluster_name}-admin"
  admin_role_arn  = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.admin_role_name}"

  admin_access_entries = var.create_admin_role ? {
    (local.admin_role_arn) = ["arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"]
  } : {}

  # Explicit access_entries plus the managed admin role.
  all_access_entries = merge(var.access_entries, local.admin_access_entries)
}

# --- Cluster role ----------------------------------------------------------- #
data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
  ])
  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# --- Node role ------------------------------------------------------------- #
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# --- Dedicated cluster-admin role --------------------------------------- #
# An assumable IAM role wired to the AmazonEKSClusterAdminPolicy access entry.
# Trust defaults to the account root (any principal in the account that IAM
# policy lets call sts:AssumeRole on it); pass admin_role_trusted_principals to
# restrict it to specific users / SSO roles.
data "aws_iam_policy_document" "admin_assume_role" {
  count = var.create_admin_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type = "AWS"
      identifiers = length(var.admin_role_trusted_principals) > 0 ? var.admin_role_trusted_principals : [
        "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root",
      ]
    }
  }
}

resource "aws_iam_role" "admin" {
  count = var.create_admin_role ? 1 : 0

  name               = local.admin_role_name
  assume_role_policy = data.aws_iam_policy_document.admin_assume_role[0].json
  tags               = var.tags
}

# Lets the assumed role discover the cluster for `aws eks update-kubeconfig`.
# Kubernetes RBAC itself comes from the EKS access entry, not this policy.
resource "aws_iam_role_policy" "admin_eks_read" {
  count = var.create_admin_role ? 1 : 0

  name = "eks-describe"
  role = aws_iam_role.admin[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

# --- IRSA / OIDC provider ------------------------------------------------- #
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  tags            = var.tags
}
