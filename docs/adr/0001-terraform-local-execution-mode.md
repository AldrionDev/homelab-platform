# Use Local execution mode for the Platform Terraform Workspace

HCP Terraform's default is remote (cloud-hosted) execution, but this Platform's
`kubernetes` and `helm` providers must reach the k3s API, which is only exposed on the
local LAN and is not internet-routable. HCP Terraform's cloud-hosted runners cannot
reach it. We use **Local** execution mode: `terraform plan`/`apply` run on the Host
itself, while HCP Terraform is used only for remote state storage. This is a
deliberate deviation from the platform default (Remote execution) and should not be
"corrected" back to Remote — doing so would break every `apply` against this cluster
until the Host is made reachable from HCP Terraform's runners, which is out of scope
for a single-node home LAN.
