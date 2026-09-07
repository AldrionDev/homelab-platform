# Issue #8: the first concrete instantiation of the Namespace Pattern
# (terraform/modules/namespace-resourcequota/) — reserves the `homestreamlab`
# namespace for HomeStreamLab's future deployment. No application resources
# (Deployment/Service/Ingress/Secret/Jenkinsfile) belong here or anywhere in
# this repository — see CLAUDE.md "Do not add".
module "homestreamlab" {
  source = "../modules/namespace-resourcequota"

  project_name = "homestreamlab"

  # Explicitly approved platform quota policy values for this issue.
  cpu_request    = "1"
  cpu_limit      = "2"
  memory_request = "2Gi"
  memory_limit   = "4Gi"
}

# Issue #38: platform allocation for HomeOps. Application workloads remain in
# the separate HomeOps repository.
module "homeops" {
  source = "../modules/namespace-resourcequota"

  project_name = "homeops"

  cpu_request    = "500m"
  cpu_limit      = "1"
  memory_request = "512Mi"
  memory_limit   = "1Gi"
}

# Issue #41: platform allocation for OmniVise IoT. Application workloads,
# Services, storage, config and the IngressRoute instance remain in the
# separate omnivise-iot repository / its future omnivise-iot-k8s workspace,
# which must reference this namespace, never recreate it.
module "omnivise_iot" {
  source = "../modules/namespace-resourcequota"

  project_name = "omnivise-iot"

  # Explicitly approved platform quota policy values for this project
  # (same profile as homestreamlab).
  cpu_request    = "1"
  cpu_limit      = "2"
  memory_request = "2Gi"
  memory_limit   = "4Gi"
}
