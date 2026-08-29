# fdp-infra-compute

Terraform for the **fdp** EKS cluster in London (`eu-west-2`, region short `euw2`).

Networking (VPC, subnets, shared EKS SG) lives in **fdp-infra-networking** and is
consumed here via `terraform_remote_state`. Downstream app/helm repos read this
repo's remote state for the cluster endpoint, CA data and OIDC provider ARN.

## Layout

```
eks_main.tf              root: locals (dev/prod config sets), provider, VPC remote state, module call
backend.tf               S3 backend — bucket + region hardcoded, key passed at init
versions.tf              required_version >= 1.10.0; aws ~> 5.60, tls ~> 4.0
outputs.tf               re-exported module outputs + resource_prefix
modules/eks/             cluster + node groups + IRSA/OIDC + access entries + core addons
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
| Node instance type | `t3.medium` | `t3.large` |
| desired / min / max | 2 / 2 / 4 | 3 / 3 / 6 |
| Public API endpoint | open (`0.0.0.0/0`) | restricted (`public_access_cidrs`) |
| Kubernetes version | 1.31 | 1.31 |

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

`cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`
(sensitive), `cluster_version`, `cluster_security_group_id`,
`oidc_provider_arn`, `oidc_provider_url`, `node_iam_role_arn`,
`eks_admin_role_arn`, `kubeconfig_command`, `resource_prefix`.
