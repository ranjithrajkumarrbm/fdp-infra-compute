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
  ConfigMap), managed addons `vpc-cni` / `coredns` / `kube-proxy` /
  `aws-ebs-csi-driver`.
- Cluster admin is granted to the principal ARN in
  `local.access_entries` via `AmazonEKSClusterAdminPolicy`.

## Prerequisites

- **fdp-infra-networking must be applied first** for the target environment. Its
  state must exist at `fdp-infra-networking/<env>/terraform.tfstate` in the
  shared bucket, exposing `vpc_id`, `private_app_subnet_ids`,
  `private_db_subnet_ids`, `eks_security_group_id`.
- Shared state bucket: `fdp-infra-state-bucket-861477414666-eu-west-2-an`
  (same AWS account as the networking repo — the CI keys already used there need
  no extra IAM).

## Fill these placeholders before applying

| File | Placeholder | Value |
|---|---|---|
| `eks_main.tf` → `locals.access_entries` | `REPLACE-admin-role-arn` | IAM/SSO role ARN to grant cluster admin |
| `eks_main.tf` → `env_configs.prod.public_access_cidrs` | `REPLACE-vpn-or-office-cidr/32` | Office / VPN CIDR(s) |

## Usage

```bash
# dev
terraform init -backend-config="key=fdp-infra-compute/dev/terraform.tfstate"
terraform plan  -var="environment=dev"
terraform apply -var="environment=dev"

# prod (re-init to switch state)
terraform init -reconfigure -backend-config="key=fdp-infra-compute/prod/terraform.tfstate"
terraform plan -var="environment=prod"

# post-apply
aws eks update-kubeconfig --name fdp-dev-euw2-eks --region eu-west-2
```

## CI/CD

| Workflow | Trigger | Action |
|---|---|---|
| `terraform-plan.yml` | PR to `main` (matrix dev + prod); manual dispatch | `fmt -check` → `init` → `validate` → `plan`, posted as a PR comment |
| `terraform-apply.yml` | push to `main` → `dev`; manual dispatch picks env | `init` → `validate` → `apply -auto-approve` |
| `terraform-destroy.yml` | manual dispatch only | requires `confirm` input `== "destroy"`, then `destroy` |

**Required GitHub config:**

- Secrets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (repo-level or per
  Environment).
- Environments `dev` and `prod`; add required reviewers to `prod` to gate
  `apply` / `destroy`.
- Branch protection on `main` requiring the plan check.

## Outputs

`cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`
(sensitive), `cluster_version`, `cluster_security_group_id`,
`oidc_provider_arn`, `oidc_provider_url`, `node_iam_role_arn`,
`kubeconfig_command`, `resource_prefix`.
