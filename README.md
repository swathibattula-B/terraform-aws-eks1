# terraform-aws-eks

This module creates a private EKS cluster on AWS. The cluster endpoint is not exposed to the internet — you need a bastion or VPN to reach it. Whoever runs `terraform apply` automatically gets admin access to the cluster, no extra setup needed.

Node groups are fully configurable via a map — you can run blue and green node groups side by side, which makes Kubernetes version upgrades much safer.

---

## What gets created

| Resource | Name | Notes |
|---|---|---|
| `aws_eks_cluster` | `{project}-{environment}` | Private endpoint only |
| `aws_eks_node_group` | `{project}-{environment}-{blue\|green}` | One per active entry in `eks_managed_node_groups` |
| `aws_launch_template` | `{project}-{environment}-{blue\|green}-lt` | gp3 disk, IMDSv2 hop limit 2, custom SGs |
| `aws_iam_role` | `{project}-{environment}-eks-cluster` | Assumed by EKS control plane |
| `aws_iam_role` | `{project}-{environment}-eks-node` | Assumed by all node groups |
| `aws_iam_role_policy_attachment` | — | `AmazonEKSClusterPolicy` on cluster role |
| `aws_iam_role_policy_attachment` | — | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` on node role |
| `aws_iam_role_policy_attachment` | — | Any extra policies from `iam_role_additional_policies` (e.g. EBS, EFS) |
| `aws_iam_openid_connect_provider` | `{project}-{environment}-oidc` | Enables IRSA — pods assuming IAM roles |
| `aws_eks_addon` | `vpc-cni` | Installed before nodes |
| `aws_eks_addon` | `eks-pod-identity-agent` | Installed before nodes |
| `aws_eks_addon` | `coredns` | Installed after nodes |
| `aws_eks_addon` | `kube-proxy` | Installed after nodes |
| `aws_eks_addon` | `metrics-server` | Installed after nodes |

---

## Basic usage

```hcl
module "eks" {
  source = "../terraform-aws-eks"

  project     = "roboshop"
  environment = "dev"

  vpc_id             = local.vpc_id
  private_subnet_ids = local.private_subnet_ids

  cluster_security_group_ids = [local.eks_control_plane_sg_id]
  node_security_group_ids    = [local.eks_node_sg_id]

  eks_managed_node_groups = {
    blue = {
      instance_types = ["m5.xlarge"]
      min_size       = 2
      max_size       = 10
      desired_size   = 2
      labels         = { nodegroup = "blue" }
      iam_role_additional_policies = {
        amazonEBS = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        amazonEFS = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
      }
    }
  }
}
```

---

## Blue-Green node group upgrade

The whole point of the `eks_managed_node_groups` map is to make upgrades easy. You never touch the module — just flip variables in the consumer.

```hcl
# variables in your 40-eks consumer
variable "eks_version"                 { default = "1.30" }
variable "enable_blue"                 { default = true }
variable "enable_green"                { default = false }
variable "eks_nodegroup_green_version" { default = "1.31" }
```

```hcl
module "eks" {
  source          = "../terraform-aws-eks"
  cluster_version = var.eks_version

  eks_managed_node_groups = {
    blue = {
      create         = var.enable_blue
      # no kubernetes_version here — picks up cluster_version automatically
      instance_types = ["m5.xlarge"]
      capacity_type  = "SPOT"
      min_size       = 2
      max_size       = 10
      desired_size   = 2
      labels         = { nodegroup = "blue" }
      iam_role_additional_policies = {
        amazonEBS = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        amazonEFS = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
      }
    }

    green = {
      create             = var.enable_green
      kubernetes_version = var.eks_nodegroup_green_version  # only matters during upgrade
      instance_types     = ["m5.xlarge"]
      capacity_type      = "SPOT"
      min_size           = 2
      max_size           = 10
      desired_size       = 2
      labels             = { nodegroup = "green" }
      iam_role_additional_policies = {
        amazonEBS = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        amazonEFS = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
      }
    }
  }
}
```

**Upgrade steps:**

Control plane must be upgraded first — AWS does not allow a node group to run a version higher than the control plane. Nodes can be up to 2 minor versions behind the control plane, so blue stays running fine while you bring green up.

```bash
# 1. Upgrade control plane, pin blue at old version
terraform apply \
  -var="eks_version=1.35" \
  -var="eks_nodegroup_blue_version=1.34"

# Control plane is now 1.35, blue nodes still on 1.34 — AWS allows this (within 2 versions)

# 2. Upgrade add-ons to latest versions compatible with 1.35
# Terraform does not auto-update addon versions — must be done via CLI after control plane upgrade
for addon in vpc-cni eks-pod-identity-agent coredns kube-proxy metrics-server; do
  LATEST=$(aws eks describe-addon-versions \
    --kubernetes-version 1.35 \
    --addon-name $addon \
    --query 'addons[0].addonVersions[0].addonVersion' \
    --output text)

  aws eks update-addon \
    --cluster-name roboshop-dev \
    --addon-name $addon \
    --addon-version $LATEST \
    --resolve-conflicts OVERWRITE \
    --region us-east-1
done

# Wait for all addons to become Active
aws eks wait addon-active --cluster-name roboshop-dev --addon-name vpc-cni --region us-east-1
aws eks wait addon-active --cluster-name roboshop-dev --addon-name coredns --region us-east-1
aws eks wait addon-active --cluster-name roboshop-dev --addon-name kube-proxy --region us-east-1

# 3. Bring green up on the new version
terraform apply \
  -var="eks_version=1.35" \
  -var="eks_nodegroup_blue_version=1.34" \
  -var="enable_green=true" \
  -var="eks_nodegroup_green_version=1.35"

# 4. Cordon all blue nodes — stops new pods scheduling on them
kubectl cordon -l nodegroup=blue

# 5. Drain blue nodes one by one — pods reschedule to green, PDBs respected
for node in $(kubectl get nodes -l nodegroup=blue -o name); do
  kubectl drain $node --ignore-daemonsets --delete-emptydir-data
done

# 6. Verify all pods are running on green before removing blue
kubectl get pods -o wide

# 7. Remove blue
terraform apply \
  -var="eks_version=1.35" \
  -var="enable_blue=false" \
  -var="enable_green=true"
```

---

## Node group config options

Each entry in `eks_managed_node_groups` supports these fields. Everything has a default so you only need to set what you want to change.

| Field | Default | Notes |
|-------|---------|-------|
| `create` | `true` | Set to `false` to skip this node group without deleting it from config |
| `ami_type` | `AL2023_x86_64_STANDARD` | Amazon Linux 2023 |
| `kubernetes_version` | `""` | Empty means it follows `cluster_version` |
| `instance_types` | `["t3.medium"]` | Pass multiple types for SPOT diversity |
| `capacity_type` | `ON_DEMAND` | `SPOT` saves ~70% cost, with interruption risk |
| `disk_size` | `20` | Root volume in GiB, gp3 type |
| `min_size` | `1` | |
| `max_size` | `5` | |
| `desired_size` | `2` | |
| `labels` | `{}` | Kubernetes node labels |
| `taints` | `{}` | Kubernetes node taints |
| `iam_role_additional_policies` | `{}` | Extra IAM policies, e.g. EBS/EFS CSI |

---

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `project` | Project name, used in all resource names | `string` | — | yes |
| `environment` | One of: dev, qa, uat, prod | `string` | — | yes |
| `vpc_id` | VPC to create the cluster in | `string` | — | yes |
| `private_subnet_ids` | Private subnets for control plane and nodes | `list(string)` | — | yes |
| `cluster_version` | Kubernetes version for the control plane | `string` | `"1.34"` | no |
| `cluster_security_group_ids` | Extra SGs for the control plane — you create these | `list(string)` | `[]` | no |
| `node_security_group_ids` | SGs attached to nodes via launch template — you create these | `list(string)` | `[]` | no |
| `eks_managed_node_groups` | Map of node group configs — see table above | `map(object)` | `{ blue = {} }` | no |
| `cluster_tags` | Extra tags on the EKS cluster | `map(string)` | `{}` | no |

---

## Outputs

| Name | Description |
|------|-------------|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | API server URL — only reachable from inside the VPC |
| `cluster_certificate_authority` | CA data for kubeconfig |
| `cluster_security_group_id` | The SG that EKS auto-creates for the cluster |
| `cluster_version` | Kubernetes version on the control plane |
| `node_group_ids` | Map of node group IDs, e.g. `{ blue = "...", green = "..." }` |
| `node_group_statuses` | Map of node group statuses — handy during upgrades |
| `cluster_role_arn` | IAM role ARN used by the control plane |
| `node_role_arn` | IAM role ARN used by nodes |
| `oidc_provider_arn` | Pass this to any IRSA role you create |
| `oidc_issuer` | OIDC URL without https:// — used in IRSA trust policies |
| `admin_iam_arn` | The IAM identity that got admin access when the cluster was created |

---

## IAM roles

Two IAM roles are created automatically.

**Cluster role** (`roboshop-dev-eks-cluster`) — used by the EKS control plane:
- `AmazonEKSClusterPolicy`

**Node role** (`roboshop-dev-eks-node`) — used by all node groups:
- `AmazonEKSWorkerNodePolicy` — lets nodes register with the cluster
- `AmazonEKS_CNI_Policy` — lets vpc-cni assign pod IPs
- `AmazonEC2ContainerRegistryReadOnly` — pull images from ECR
- anything extra you pass in `iam_role_additional_policies` (e.g. EBS, EFS)

Note: EBS and EFS policies are not hardcoded — pass them via `iam_role_additional_policies` so each project only attaches what it actually uses.

---

## Add-ons

| Add-on | Installed before nodes? | Why |
|--------|------------------------|-----|
| `vpc-cni` | yes | Nodes need pod networking ready when they join |
| `eks-pod-identity-agent` | yes | Must be ready before any workloads schedule |
| `coredns` | no | Needs nodes to run on |
| `kube-proxy` | no | Needs nodes to run on |
| `metrics-server` | no | Needs nodes to run on |

---

## Security groups

This module does not create security groups — that's your responsibility. Pass them in via:

- `cluster_security_group_ids` — attached to the EKS control plane (port 443 from your bastion/VPN)
- `node_security_group_ids` — attached to nodes via launch template

EKS always attaches its own auto-created cluster SG to nodes on top of yours, so control plane ↔ node communication is never broken regardless of what you pass in.

---

## After terraform apply

Run these from your bastion or VPN:

```bash
# connect kubectl to the cluster
aws eks update-kubeconfig --name roboshop-dev --region us-east-1

# check nodes are up
kubectl get nodes

# install AWS Load Balancer Controller (needed for ingress)
VPC_ID=$(aws ssm get-parameter --name /roboshop/dev/vpc_id \
  --region us-east-1 --query Parameter.Value --output text)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=roboshop-dev \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=$VPC_ID
```

---

## Requirements

| Tool | Version |
|------|---------|
| Terraform | `>= 1.5.0` |
| AWS provider | `~> 6.0` |
| TLS provider | `~> 4.0` |

---

## Resource naming

Everything follows `{project}-{environment}`:

```
roboshop-dev                      EKS cluster
roboshop-dev-blue                 blue node group
roboshop-dev-green                green node group
roboshop-dev-blue-lt              blue launch template
roboshop-dev-eks-cluster          cluster IAM role
roboshop-dev-eks-node             node IAM role
roboshop-dev-oidc                 OIDC provider
roboshop-dev-blue-node            EC2 instance name tag
roboshop-dev-blue-volume          EBS volume name tag
```
