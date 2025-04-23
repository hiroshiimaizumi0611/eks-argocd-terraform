output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}
output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "node_group_role_arn" {
  value = module.eks.eks_managed_node_groups
}
