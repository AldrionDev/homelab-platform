# Both providers target the same single-node k3s cluster through the same
# kubeconfig. Issue #6 contains no resources or data sources requiring Kubernetes
# API operations; therefore its empty baseline plan is not treated as evidence of
# live provider-to-cluster connectivity.

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}

provider "helm" {
  # helm provider v3 takes `kubernetes` as an attribute, not a nested block.
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kube_context
  }
}
