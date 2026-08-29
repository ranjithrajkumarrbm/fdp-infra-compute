###############################################################################
# AWS Load Balancer Controller
#
# Installs the controller via Helm into kube-system with an IRSA role scoped to
# the cluster OIDC provider, plus the AWS-published IAM policy. An "alb"
# IngressClass / IngressClassParams is created with scheme = internal, so every
# Kubernetes Ingress that sets `ingressClassName: alb` provisions an INTERNAL
# ALB in the private application subnets (var.subnet_ids).
#
# A dedicated frontend security group (aws_security_group.alb) is created for
# those ALBs - downstream repos (e.g. API Gateway HTTP API + VPC Link) consume
# its ID. The application repo attaches it to the Ingress with
#   alb.ingress.kubernetes.io/security-groups: <alb_security_group_id>
# and this module opens the matching path from that SG to the node targets on
# the EKS cluster security group.
###############################################################################

locals {
  alb_controller_enabled = var.enable_alb_controller

  alb_sa_name      = "aws-load-balancer-controller"
  alb_sa_namespace = "kube-system"
  alb_oidc_host    = replace(aws_iam_openid_connect_provider.this.url, "https://", "")

  # CIDRs allowed to reach the internal ALB frontend. Empty => the VPC CIDR.
  alb_allowed_cidrs = length(var.alb_allowed_cidrs) > 0 ? var.alb_allowed_cidrs : [data.aws_vpc.this.cidr_block]
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

# --- IRSA role + AWS-published IAM policy -------------------------------- #
data "aws_iam_policy_document" "alb_controller_assume_role" {
  count = local.alb_controller_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.alb_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.alb_oidc_host}:sub"
      values   = ["system:serviceaccount:${local.alb_sa_namespace}:${local.alb_sa_name}"]
    }
  }
}

resource "aws_iam_policy" "alb_controller" {
  count = local.alb_controller_enabled ? 1 : 0

  name        = "${local.cluster_name}-alb-controller"
  description = "AWS Load Balancer Controller (${local.cluster_name})"
  policy      = file("${path.module}/alb_controller_iam_policy.json")
  tags        = var.tags
}

resource "aws_iam_role" "alb_controller" {
  count = local.alb_controller_enabled ? 1 : 0

  name               = "${local.cluster_name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  count = local.alb_controller_enabled ? 1 : 0

  role       = aws_iam_role.alb_controller[0].name
  policy_arn = aws_iam_policy.alb_controller[0].arn
}

# --- Frontend security group for the internal ALBs --------------------- #
resource "aws_security_group" "alb" {
  count = local.alb_controller_enabled ? 1 : 0

  name        = "${local.cluster_name}-alb-internal"
  description = "Internal ALB frontend for aws-load-balancer-controller Ingresses"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${local.cluster_name}-alb-internal" })

  lifecycle {
    create_before_destroy = true
  }
}

# Clients (in-VPC callers, API Gateway VPC Link ENIs) -> internal ALB.
resource "aws_vpc_security_group_ingress_rule" "alb_client" {
  for_each = local.alb_controller_enabled ? {
    for pair in setproduct(local.alb_allowed_cidrs, var.alb_listener_ports) :
    "${pair[0]}_${pair[1]}" => { cidr = pair[0], port = pair[1] }
  } : {}

  security_group_id = aws_security_group.alb[0].id
  description       = "Client to internal ALB :${each.value.port}"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  tags              = var.tags
}

# Internal ALB -> pod / node targets inside the VPC.
resource "aws_vpc_security_group_egress_rule" "alb_to_targets" {
  count = local.alb_controller_enabled ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  description       = "Internal ALB to in-VPC targets"
  cidr_ipv4         = data.aws_vpc.this.cidr_block
  ip_protocol       = "tcp"
  from_port         = 1
  to_port           = 65535
  tags              = var.tags
}

# Allow the internal ALB frontend SG to reach the worker nodes. Covers both
# target-type ip (pod containerPort, typically > 1024) and target-type instance
# (NodePort range 30000-32767). The nodes attach the EKS cluster security group.
resource "aws_vpc_security_group_ingress_rule" "alb_to_nodes" {
  count = local.alb_controller_enabled ? 1 : 0

  security_group_id            = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_security_group.alb[0].id
  description                  = "Internal ALB (aws-load-balancer-controller) to node targets"
  ip_protocol                  = "tcp"
  from_port                    = 1025
  to_port                      = 65535
  tags                         = var.tags
}

# --- Private app subnet discovery tag --------------------------------- #
# The controller auto-discovers subnets for an internal load balancer by this
# tag when the Ingress does not pin subnets explicitly.
resource "aws_ec2_tag" "internal_elb" {
  for_each = local.alb_controller_enabled ? toset(var.subnet_ids) : toset([])

  resource_id = each.value
  key         = "kubernetes.io/role/internal-elb"
  value       = "1"
}

# --- Helm release ---------------------------------------------------- #
resource "helm_release" "alb_controller" {
  count = local.alb_controller_enabled ? 1 : 0

  name       = "aws-load-balancer-controller"
  namespace  = local.alb_sa_namespace
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version

  # Wait for the controller to be rolled out so downstream Ingresses reconcile.
  wait    = true
  timeout = 600

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "vpcId"
    value = var.vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = local.alb_sa_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller[0].arn
  }

  # Create the "alb" IngressClass and an IngressClassParams that forces every
  # Ingress using it to an INTERNAL scheme.
  set {
    name  = "createIngressClassResource"
    value = "true"
  }
  set {
    name  = "ingressClass"
    value = "alb"
  }
  set {
    name  = "ingressClassParams.create"
    value = "true"
  }
  set {
    name  = "ingressClassParams.name"
    value = "alb"
  }
  set {
    name  = "ingressClassParams.spec.scheme"
    value = "internal"
  }

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.alb_controller,
    aws_eks_addon.this,
  ]
}
