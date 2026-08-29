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
modules/eks/alb_controller.tf   AWS Load Balancer Controller: IRSA role + IAM policy + Helm release + internal-ALB SG + subnet tags
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
| Kubernetes version | 1.31 | 1.31 |
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

## AWS Load Balancer Controller (internal ALB)

`modules/eks/alb_controller.tf` installs the [AWS Load Balancer
Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
(Helm chart `aws-load-balancer-controller`, default `1.13.3` / app `v2.13.3`)
so a Kubernetes **Ingress** provisions an **internal** ALB in the VPC private
application subnets. It creates:

| Resource | Name | Purpose |
|---|---|---|
| IAM policy | `fdp-<env>-euw2-eks-alb-controller` | AWS-published controller policy (`modules/eks/alb_controller_iam_policy.json`) |
| IAM role (IRSA) | `fdp-<env>-euw2-eks-alb-controller` | Trusts the cluster OIDC provider for `kube-system/aws-load-balancer-controller` |
| Helm release | `aws-load-balancer-controller` (ns `kube-system`) | The controller + an `alb` `IngressClass` / `IngressClassParams` with `scheme: internal` |
| Security group | `fdp-<env>-euw2-eks-alb-internal` | Frontend SG for the internal ALBs; consumed by the app repo and by API Gateway VPC Link |
| SG rules | on the SG above + the EKS cluster SG | Clients → ALB on `alb_listener_ports` (80/443); ALB → node targets (`tcp 1025-65535`) |
| Subnet tags | `kubernetes.io/role/internal-elb = 1` on each private app subnet | Lets the controller auto-discover subnets for an internal LB |

The controller only manages load balancers when an Ingress/Service asks for one —
**it does not create the Fraud Service `Deployment` / `Service` / `Ingress`**,
which stay in the application repo.

### Module variables

| Variable | Default | Notes |
|---|---|---|
| `enable_alb_controller` | `true` | Set `false` to skip the controller, SG and tags entirely |
| `alb_controller_chart_version` | `"1.13.3"` | Helm chart version |
| `alb_allowed_cidrs` | `[]` | Client CIDRs allowed to the internal ALB frontend SG; empty ⇒ the VPC CIDR |
| `alb_listener_ports` | `[80, 443]` | Ports opened on the frontend SG |

### Application repo contract (Fraud Service Ingress)

The Ingress in the app repo must set:

```yaml
metadata:
  annotations:
    alb.ingress.kubernetes.io/security-groups: <alb_security_group_id>   # this repo's output
    alb.ingress.kubernetes.io/target-type: ip                            # route straight to pods
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'            # or HTTP:80
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
spec:
  ingressClassName: alb        # => internal ALB via the IngressClassParams
```

`scheme: internal` comes from the `IngressClassParams` this repo creates, so it
does not need to be set per-Ingress. Because the Ingress pins an explicit
frontend SG, this repo (not the controller) owns the SG rule from that SG to the
nodes — do **not** set `alb.ingress.kubernetes.io/manage-backend-security-group-rules`.

### Downstream: API Gateway HTTP API + VPC Link

VPC Link (v2) needs subnet + security-group IDs, exported here as
`private_app_subnet_ids` and `alb_security_group_id` (reuse the same SG). The
**ALB listener ARN** is created by the app repo's Ingress, not this repo —
read it at runtime:

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName, 'internal-')].[LoadBalancerArn,DNSName,Scheme]" --output table
```

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
terraform apply -var="environment=dev"     # controller + SG on the second pass
# or set enable_alb_controller=false for the first apply, then flip it back
```

### Validate the internal ALB path

```bash
# controller is running and the internal IngressClass exists
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller
kubectl get ingressclass alb
kubectl get ingressclassparams alb -o jsonpath='{.spec.scheme}{"\n"}'   # -> internal

# after the application repo deploys the Fraud Service Ingress:
kubectl get ingress -A
kubectl get ingress <name> -n <ns> -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
#   -> internal-<...>.eu-west-2.elb.amazonaws.com   (name starts with "internal-")

aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?contains(DNSName,'internal-')].[LoadBalancerName,Scheme,VpcId]" --output table
```

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

Load balancer / VPC Link prerequisites for downstream repos:
`alb_controller_role_arn`, `alb_ingress_class_name` (`alb`),
`alb_security_group_id`, `vpc_id`, `private_app_subnet_ids`.
