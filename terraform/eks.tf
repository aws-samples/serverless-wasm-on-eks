data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

locals {
  name            = "serverless-wasm"
  cluster_version = "1.31"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Example = local.name
  }
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=00d4cc1373d97a5abfa05b7cc75e9c9a189e4d5f"

  cluster_name                   = local.name
  cluster_version                = local.cluster_version
  cluster_endpoint_public_access = true
  cluster_ip_family              = "ipv6"
  create_cni_ipv6_iam_policy     = true

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    wasm_amd64 = {
      attach_cluster_primary_security_group = true
      iam_role_attach_cni_policy            = true
      min_size                              = 2
      max_size                              = 3
      desired_size                          = 2
      instance_types                        = ["c6i.xlarge"]
      ami_type                              = "CUSTOM"
      platform                              = "linux"
      ami_id                                = var.custom_ami_id_amd64
      user_data_template_path               = "${path.module}/templates/user-data.tpl"
      iam_role_additional_policies = {
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
    wasm_arm64 = {
      attach_cluster_primary_security_group = true
      iam_role_attach_cni_policy            = true
      min_size                              = 2
      max_size                              = 3
      desired_size                          = 2
      instance_types                        = ["c6g.xlarge"]
      ami_type                              = "CUSTOM"
      platform                              = "linux"
      ami_id                                = var.custom_ami_id_arm64
      user_data_template_path               = "${path.module}/templates/user-data.tpl"
      iam_role_additional_policies = {
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=b1f2125bf1015bfc3900feda290ade8bd0a7b871"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_ipv6            = true
  create_egress_only_igw = true

  public_subnet_ipv6_prefixes                    = [0, 1, 2]
  public_subnet_assign_ipv6_address_on_creation  = true
  private_subnet_ipv6_prefixes                   = [3, 4, 5]
  private_subnet_assign_ipv6_address_on_creation = true
  intra_subnet_ipv6_prefixes                     = [6, 7, 8]
  intra_subnet_assign_ipv6_address_on_creation   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

resource "time_sleep" "wait_60_seconds" {
  depends_on = [module.eks]
  create_duration = "60s"
}

module "load_balancer_controller_irsa_role" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-iam.git//modules/iam-role-for-service-accounts-eks?ref=15fd17540b6db8be434759e684c1cabf20a5219a"

  role_name                              = "load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  depends_on = [module.load_balancer_controller_irsa_role]
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "serviceAccount.create"
    value = true
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.load_balancer_controller_irsa_role.iam_role_arn
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceTargetENISGTags"
    value = "Name=${module.eks.cluster_name}-node"
  }
}

module "ecr-addtocart" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ecr.git?ref=124c13976f4cdc061f5b1ddb38bff715eeba2ad5"

  repository_name = "addtocart"

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 7 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 30
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "ecr-getcart" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ecr.git?ref=124c13976f4cdc061f5b1ddb38bff715eeba2ad5"

  repository_name = "getcart"

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 7 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 30
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "ecr-deletefromcart" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ecr.git?ref=124c13976f4cdc061f5b1ddb38bff715eeba2ad5"

  repository_name = "deletefromcart"

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 7 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 30
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

module "ecr-webshop" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ecr.git?ref=124c13976f4cdc061f5b1ddb38bff715eeba2ad5"

  repository_name = "webshop"

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 7 images",
        selection = {
          tagStatus     = "tagged",
          tagPrefixList = ["v"],
          countType     = "imageCountMoreThan",
          countNumber   = 30
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}