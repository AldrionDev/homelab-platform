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
