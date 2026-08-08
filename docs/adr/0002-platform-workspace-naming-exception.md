# Platform Terraform Workspace is exempt from the `<project>-k8s` naming convention

Project Terraform Workspaces follow `<project>-k8s` (e.g. `homestreamlab-k8s`) so that
onboarding a new Project is mechanical. The Platform's own workspace is named
`homelab-platform`, not `homelab-platform-k8s`. This is deliberate: the convention
identifies a *Project's* workspace as belonging to that Project; the Platform is not a
Project and applying the tenant convention to it would blur the Platform/Project
boundary this repository otherwise enforces strictly (see CONTEXT.md). A future
reader or audit should not treat this as a naming defect to fix — renaming it would
require a state migration for no behavioral benefit.
