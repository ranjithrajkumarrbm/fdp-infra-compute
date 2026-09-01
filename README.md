# fdp-infra-compute

Terraform for the **fdp** EKS cluster in London (`eu-west-2`, region short `euw2`).

Networking (VPC, subnets, shared EKS SG) lives in **fdp-infra-networking** and is
consumed here via `terraform_remote_state`. Downstream app/helm repos read this
repo's remote state for the cluster endpoint, CA data and OIDC provider ARN.

## Layout

```
eks_main.tf              root: locals (dev/prod config sets), aws + helm providers, VPC remote state, module call
backend.tf               S3 backend — bucket + region hardcoded, key passed at init
versions.tf              required_version >= 1.10.0; aws ~> 5.60, tls ~> 4.0, helm ~> 2.17
outputs.tf               re-exported module outputs + resource_prefix + ALB / VPC Link prerequisites
modules/eks/             cluster + node groups + IRSA/OIDC + access entries + core addons
modules/eks/alb_controller.tf   AWS Load Balancer Controller: IRSA role + IAM policy + Helm release + ALB SG + subnet tags
modules/eks/alb.tf              internal ALB + HTTP/HTTPS listener + "ip" target group (Fraud Service)
.github/workflows/       plan / apply / destroy pipelines
```

## Conventions

- **Prefix naming:** every resource is `fdp-<env>-euw2-…`, built from
  `local.prefix = "<app>-<env>-<regionshort>"`.
- **Environments:** a single `var.environment` (`dev` | `prod`) selects one of
  two local config sets in `eks_main.tf`. Region is fixed per repo.
- **Backend:** S3 with native lockfile (`use_lockfile = true`). Bucket and region
  are hardcoded in `backend.tf`; only `key` is supplied at `terraform init`.
- **Tags:** applied globally through the provider `default_tags` block.

### Per-environment config

| | dev | prod |
|---|---|---|
| Node instance type | `c7i-flex.large` | `c7i-flex.large` |
| desired / min / max | 2 / 2 / 4 | 3 / 3 / 6 |
| Public API endpoint | open (`0.0.0.0/0`) | restricted (`public_access_cidrs`) |
| Kubernetes version | 1.34 | 1.34 |
| Internal ALB client CIDRs (`alb_allowed_cidrs`) | `[]` → VPC CIDR | `[]` → VPC CIDR (tighten to VPC Link / consumer ranges) |

## Module (`modules/eks/`)

- **iam.tf** — cluster role (`AmazonEKSClusterPolicy`), node role
  (`AmazonEKSWorkerNodePolicy` + `AmazonEKS_CNI_Policy` +
  `AmazonEC2ContainerRegistryReadOnly`), IRSA OIDC provider
  (`tls_certificate` → `aws_iam_openid_connect_provider`).
- **eks.tf** — CloudWatch log group for control-plane logs (90-day retention),
  `aws_eks_cluster` (`authentication_mode = "API"`, `api`/`audit`/`authenticator`
  logs), managed node groups from `var.node_groups` in the VPC private app
  subnets, `aws_eks_access_entry` + policy associations (no `aws-auth`
  ConfigMap), managed addons `vpc-cni` / `coredns` / `kube-proxy`.
- **Cluster admin** — the module creates a dedicated IAM role
  `fdp-<env>-euw2-eks-admin` (`create_admin_role = true`) and wires it to the
  `AmazonEKSClusterAdminPolicy` access entry. Its trust policy defaults to the
  account root; set `eks_admin_trusted_principals` to specific IAM user / SSO
  role ARNs to restrict who may assume it. Its ARN is the `eks_admin_role_arn`
  output. Add `local.access_entries` entries for any further principals.
- Whoever runs `terraform apply` (the CI keys) is also made cluster admin via
  `bootstrap_cluster_creator_admin_permissions`.

## Internal ALB + AWS Load Balancer Controller

Two files provide the internal ingress path for the Fraud Service:

- **`modules/eks/alb_controller.tf`** installs the [AWS Load Balancer
  Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
  (Helm chart `aws-load-balancer-controller`, default `3.5.0` / app `v3.5.0`)
  with an IRSA role, plus the shared frontend security group, the SG rules, and
  the private-app-subnet discovery tags. It also registers an `alb`
  `IngressClass` (`scheme: internal`) for any *other* service that prefers the
  Ingress route.
- **`modules/eks/alb.tf`** creates a concrete **internal ALB** in the private
  application subnets with an HTTP:80 listener (and HTTPS:443 when
  `alb_certificate_arn` is set) forwarding to an `ip`-type target group.

| Resource | Name | Purpose |
|---|---|---|
| IAM policy + IRSA role | `fdp-<env>-euw2-eks-alb-controller` | AWS-published controller policy (`modules/eks/alb_controller_iam_policy.json`), trust for `kube-system/aws-load-balancer-controller` |
| Helm release | `aws-load-balancer-controller` (ns `kube-system`) | Controller + `alb` `IngressClass` / `IngressClassParams` (`scheme: internal`) + reconciles `TargetGroupBinding` |
| Security group | `fdp-<env>-euw2-eks-alb-internal` | Frontend SG on the ALB; reused as the API Gateway VPC Link SG |
| SG rules | on the SG above + the EKS cluster SG | Clients → ALB on `alb_listener_ports` (80/443, from `alb_allowed_cidrs`); ALB → node/pod targets (`tcp 1025-65535`) |
| Subnet tags | `kubernetes.io/role/internal-elb = 1` on each private app subnet | Internal-LB subnet discovery |
| **ALB** | `fdp-<env>-euw2-eks-int` | `internal`, `application`, in the private app subnets |
| **Listener(s)** | HTTP:80 always; HTTPS:443 when `alb_certificate_arn` set | Default action → the target group below |
| **Target group** | `fdp-<env>-euw2-eks-fraud` | `target_type = ip`, port `alb_target_port`, health check `alb_health_check_path` |

**The Fraud Service `Deployment` / `Service` stay in the application repo.** This
repo does not create them and does not create a Kubernetes `Ingress` for the
Fraud Service — the ALB, listener and target group exist on their own so the
VPC Link listener ARN is stable across app deploys.

### Module variables

| Variable | Default | Notes |
|---|---|---|
| `enable_alb_controller` | `true` | Controller + SG + tags; required for `create_internal_alb` |
| `alb_controller_chart_version` | `"3.5.0"` | Helm chart version (v3+ chart version == controller app version) |
| `create_internal_alb` | `true` | The ALB + listener(s) + target group |
| `alb_allowed_cidrs` | `[]` | Client CIDRs to the ALB frontend SG; empty ⇒ the VPC CIDR |
| `alb_listener_ports` | `[80, 443]` | Ports opened on the frontend SG |
| `alb_target_port` | `8080` | Pod container port the target group forwards to |
| `alb_health_check_path` | `"/healthz"` | Target group health-check path |
| `alb_certificate_arn` | `""` | ACM ARN ⇒ adds an HTTPS:443 listener |

### Application repo contract (Fraud Service)

The app repo deploys a `Deployment`, a `ClusterIP` `Service`, and a
`TargetGroupBinding` (CRD from the controller) that attaches the Service pods to
this repo's target group — **no `Ingress` needed**:

```yaml
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: fraud-service
  namespace: fraud
spec:
  serviceRef:
    name: fraud-service      # the ClusterIP Service
    port: 80
  targetGroupARN: <alb_target_group_arn>   # `terraform output alb_target_group_arn`
  targetType: ip
```

The pod container must listen on `alb_target_port` (8080) and serve
`alb_health_check_path` (`/healthz`).

### Downstream: API Gateway HTTP API + VPC Link

Everything VPC Link (v2) needs is now an output of this repo:
`private_app_subnet_ids`, `alb_security_group_id`, and a stable
`alb_listener_arn` for the integration (`vpc_id` for the link itself).

## Prerequisites

- **fdp-infra-networking must be applied first** for the target environment. Its
  state must exist at `fdp-infra-networking/<env>/terraform.tfstate` in the
  shared bucket, exposing `vpc_id`, `private_app_subnet_ids`,
  `private_db_subnet_ids`, `eks_security_group_id`.
- Shared state bucket: `fdp-infra-state-bucket-861477414666-eu-west-2-an`
  (same AWS account as the networking repo — the CI keys already used there need
  no extra IAM).

## Before applying

Nothing is strictly required — the cluster-admin role is created for you and
trusts the account root by default. Optional hardening:

| File | Setting | Why |
|---|---|---|
| `eks_main.tf` → `var.eks_admin_trusted_principals` | list of IAM user / SSO role ARNs | Restrict who can assume the cluster-admin role (default: account root) |
| `eks_main.tf` → `env_configs.prod.public_access_cidrs` | office / VPN CIDR(s) | Currently `10.0.0.0/20`; set to your real egress ranges |

## Usage

```bash
# dev
terraform init -backend-config="key=fdp-infra-compute/dev/terraform.tfstate"
terraform plan  -var="environment=dev"
terraform apply -var="environment=dev"

# prod (re-init to switch state)
terraform init -reconfigure -backend-config="key=fdp-infra-compute/prod/terraform.tfstate"
terraform plan -var="environment=prod"

# post-apply: assume the admin role, then point kubectl at the cluster
aws sts assume-role --role-arn "$(terraform output -raw eks_admin_role_arn)" --role-session-name admin
aws eks update-kubeconfig --name fdp-dev-euw2-eks --region eu-west-2
```

`terraform apply` also installs the AWS Load Balancer Controller via Helm, so the
credentials running Terraform must reach the cluster API (`aws` CLI on PATH; the
CI keys are cluster admin via `bootstrap_cluster_creator_admin_permissions`). If
the very first apply cannot reach a brand-new cluster, split it:

```bash
terraform apply -var="environment=dev" -target=module.eks.aws_eks_cluster.this -target=module.eks.aws_eks_node_group.this
terraform apply -var="environment=dev"     # controller + ALB on the second pass
# or set enable_alb_controller=false for the first apply, then flip it back
```

### Validate the internal ALB path

```bash
# ALB, listener and target group exist (immediately after apply)
terraform output alb_arn alb_listener_arn alb_target_group_arn
aws elbv2 describe-load-balancers --region eu-west-2 \
  --query "LoadBalancers[?LoadBalancerName=='fdp-dev-euw2-eks-int'].[Scheme,State.Code,VpcId]" --output table
#   -> internal   active   vpc-...

# controller is running (needed to reconcile the app repo's TargetGroupBinding)
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller

# after the application repo applies its Deployment + Service + TargetGroupBinding:
kubectl -n fraud get targetgroupbinding
aws elbv2 describe-target-health --region eu-west-2 \
  --target-group-arn "$(terraform output -raw alb_target_group_arn)" \
  --query 'TargetHealthDescriptions[].TargetHealth.State'          # -> ["healthy", ...]

# smoke test from inside the VPC (bastion / a pod):
curl -sS "http://$(terraform output -raw alb_dns_name)/healthz"
```

## Kubernetes version

Both environments run **1.34** (`env_configs.*.kubernetes_version`). 1.31–1.33
are in EKS *extended* support and billed at the higher rate, so keep this within
standard support.

The managed addons (`vpc-cni`, `coredns`, `kube-proxy`) pass
`addon_version = null`, so EKS resolves the default that matches the cluster
version automatically — no per-addon bump needed.

**Fresh cluster (current state — cluster + node groups were deleted manually):**
just `terraform apply`; it creates the 1.34 control plane and 1.34 nodes in one
pass. The AWS Load Balancer Controller Helm chart is `3.5.0` (v3 chart version
tracks the app version) and ships its own CRDs on first install.

**In-place minor bump (one minor at a time, e.g. 1.34 → 1.35 later):**

```bash
# 1. control plane first
terraform apply -var="environment=dev" -target=module.eks.aws_eks_cluster.this
# 2. then the node groups (rolling; respects max_unavailable_percentage = 33)
terraform apply -var="environment=dev"
```

If you bump the controller chart across a major (v1.x → v3.x) on an existing
cluster, re-apply its CRDs afterwards — `helm upgrade` does not:

```bash
kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
```

### Test the upgrade

```bash
aws eks update-kubeconfig --name fdp-dev-euw2-eks --region eu-west-2

terraform output cluster_version                       # -> 1.34
aws eks describe-cluster --name fdp-dev-euw2-eks --region eu-west-2 \
  --query 'cluster.{version:version,status:status}'    # -> 1.34 / ACTIVE

kubectl version -o json | jq '.serverVersion.gitVersion'   # -> v1.34.x
kubectl get nodes -o wide                                   # every node v1.34.x, Ready
kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'

# core components healthy on the new version
kubectl -n kube-system get pods
aws eks list-addons --cluster-name fdp-dev-euw2-eks --region eu-west-2
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
kubectl -n kube-system rollout status deploy/coredns

kubectl get --raw='/readyz?verbose'                    # all checks ok
kubectl run smoke --image=public.ecr.aws/amazonlinux/amazonlinux:2023 --rm -it --restart=Never -- /bin/true
```

Repeat with `environment=prod` after dev looks good.

## CI/CD

All three workflows are **manual only** (`workflow_dispatch`) with a `dev`/`prod`
environment picker. Nothing runs on push or PR.

| Workflow | Trigger | Action |
|---|---|---|
| `terraform-plan.yml` | manual dispatch (pick env) | `fmt -check` → `init` → `validate` → `plan`; job summary |
| `terraform-apply.yml` | manual dispatch (pick env) | `init` → `validate` → `apply -auto-approve`; outputs to summary |
| `terraform-destroy.yml` | manual dispatch (pick env) | requires `confirm` input `== "destroy"`, then `destroy` |

Run them from the **Actions** tab, or:

```bash
gh workflow run terraform-plan.yml  -f environment=dev
gh workflow run terraform-apply.yml -f environment=dev
```

**Required GitHub config:**

- Secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (repo-level or per
  Environment).
- Environments `dev` and `prod`; add required reviewers to `prod` to gate
  `apply` / `destroy`.

## Outputs

Cluster: `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`
(sensitive), `cluster_version`, `cluster_security_group_id`,
`oidc_provider_arn`, `oidc_provider_url`, `node_iam_role_arn`,
`eks_admin_role_arn`, `kubeconfig_command`, `resource_prefix`, `aws_region`.

Internal ALB / VPC Link prerequisites for downstream repos:
`alb_controller_role_arn`, `alb_ingress_class_name` (`alb`),
`alb_security_group_id`, `alb_arn`, `alb_dns_name`, `alb_zone_id`,
`alb_listener_arn`, `alb_target_group_arn`, `vpc_id`, `private_app_subnet_ids`.
