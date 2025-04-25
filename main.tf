module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  name = "eks-vpc"
  cidr = var.vpc_cidr

  azs = ["ap-northeast-1a", "ap-northeast-1c"]
  public_subnets = [
    "10.0.11.0/24", # public-firewall-a
    "10.0.21.0/24", # public-alb-a
    "10.0.12.0/24", # public-firewall-c
    "10.0.22.0/24", # public-alb-c
  ]

  private_subnets = [
    "10.0.31.0/24", # private-eks-a
    "10.0.32.0/24", # private-eks-c
  ]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Project = "eks-refactor"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"

  cluster_name                   = var.cluster_name
  cluster_version                = "1.29"
  cluster_endpoint_public_access = true
  subnet_ids                     = module.vpc.private_subnets
  vpc_id                         = module.vpc.vpc_id

  eks_managed_node_groups = {
    default = {
      desired_size = 2
      max_size     = 3
      min_size     = 1

      instance_types = ["t3.medium"]
    }
  }
}

resource "null_resource" "kubeconfig" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name      = "argocd"
  namespace = "argocd"
  chart     = "./argo-cd"
  version   = "5.46.4"

  # Ingressを有効化
  set {
    name  = "server.ingress.enabled"
    value = "true"
  }

  # ALB用のIngress Class
  set {
    name  = "server.ingress.ingressClassName"
    value = "alb"
  }

  # ALBをパブリックで作成
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/scheme"
    value = "internet-facing"
  }

  # ALBのターゲットを Pod IP に
  set {
    name  = "server.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/target-type"
    value = "ip"
  }

  # Serviceは ClusterIP にしておく（ALB経由でアクセスするため）
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [null_resource.kubeconfig, kubernetes_namespace.argocd]
}
