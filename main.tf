module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  name = "eks-vpc"
  cidr = var.vpc_cidr

  azs = ["ap-northeast-1a", "ap-northeast-1c"]
  public_subnets = [
    # "10.0.11.0/24", # public-firewall-a
    "10.0.21.0/24", # public-alb-a
    # "10.0.12.0/24", # public-firewall-c
    "10.0.22.0/24", # public-alb-c
  ]


  private_subnets = [
    "10.0.31.0/24", # private-eks-a
    "10.0.32.0/24", # private-eks-c
  ]

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

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

  # Ingressのホスト制限を削除
  set {
    name  = "server.ingress.hosts[0]"
    value = ""
  }

  # HTTPS を無効化
  set {
    name  = "server.ingress.https"
    value = "false"
  }

  # TLS を完全に無効化（念のため）
  set {
    name  = "server.ingress.tls.enabled"
    value = "false"
  }
  set {
    name  = "server.ingress.tls.secretName"
    value = ""
  }

  set {
    name  = "server.insecure"
    value = "true"
  }

  set {
    name  = "server.service.servicePortHttp"
    value = "80"
  }

  depends_on = [null_resource.kubeconfig, kubernetes_namespace.argocd]
}

# ① OIDC Provider
# data "aws_eks_cluster" "this" {
#   name = module.eks.cluster_name
# }

# data "aws_eks_cluster_auth" "this" {
#   name = module.eks.cluster_name
# }

data "aws_iam_policy_document" "oidc_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "alb-controller-irsa"
  assume_role_policy = data.aws_iam_policy_document.oidc_assume_role.json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

# ② HelmでALB Controllerデプロイ
resource "helm_release" "alb_controller" {
  name      = "aws-load-balancer-controller"
  namespace = "kube-system"
  chart     = "./aws-load-balancer-controller"
  version   = "1.7.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  set {
    name  = "server.service.servicePortHttp"
    value = "80"
  }

  depends_on = [
    aws_iam_role_policy_attachment.alb_controller,
    null_resource.kubeconfig
  ]
}
