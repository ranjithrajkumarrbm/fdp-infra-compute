###############################################################################
# Internal Application Load Balancer (created by this repo)
#
# A concrete internal ALB in the VPC private application subnets, sharing the
# aws_security_group.alb frontend SG and the SG-to-node rule defined in
# alb_controller.tf. The ALB, its listener(s) and an "ip" target group are
# managed here so downstream repos (API Gateway HTTP API + VPC Link) have a
# stable listener ARN that exists independently of application deploys.
#
# The Fraud Service Deployment/Service stay in the application repo; it wires
# its pods to `alb_target_group_arn` with a TargetGroupBinding (from the AWS
# Load Balancer Controller) - no Kubernetes Ingress required.
###############################################################################

locals {
  create_alb = var.create_internal_alb

  alb_name          = "${local.cluster_name}-int"
  alb_tg_name       = "${local.cluster_name}-fraud"
  alb_https_enabled = local.create_alb && var.alb_certificate_arn != ""
}

resource "aws_lb" "internal" {
  count = local.create_alb ? 1 : 0

  name               = local.alb_name
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = var.subnet_ids

  drop_invalid_header_fields = true

  tags = merge(var.tags, { Name = local.alb_name })

  lifecycle {
    precondition {
      condition     = !var.create_internal_alb || var.enable_alb_controller
      error_message = "create_internal_alb requires enable_alb_controller = true (shared frontend security group + TargetGroupBinding registration)."
    }
  }
}

resource "aws_lb_target_group" "fraud" {
  count = local.create_alb ? 1 : 0

  name        = local.alb_tg_name
  port        = var.alb_target_port
  protocol    = "HTTP"
  target_type = "ip" # pods, via the VPC CNI
  vpc_id      = var.vpc_id

  health_check {
    path                = var.alb_health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  count = local.create_alb ? 1 : 0

  load_balancer_arn = aws_lb.internal[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fraud[0].arn
  }

  tags = var.tags
}

# Optional HTTPS listener, added only when an ACM certificate ARN is supplied.
resource "aws_lb_listener" "https" {
  count = local.alb_https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.internal[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.fraud[0].arn
  }

  tags = var.tags
}
