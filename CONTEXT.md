# Homelab Platform

`homelab-platform` is the reusable local infrastructure substrate — a single bare-metal
host running k3s, a container registry, wildcard DNS, Terraform-managed cluster
resources, and a generic backup mechanism — that future local projects (starting with
HomeStreamLab) deploy onto rather than provisioning their own infrastructure from
scratch. This document defines the platform's vocabulary, not its installation steps;
see `docs/*-runbook.md` for operational procedures.

## Language

**Platform**:
The complete set of reusable, project-independent infrastructure this repository
provisions and operates on a single host: k3s, the container registry, DNS, the
Terraform backend and its reusable patterns, and the backup mechanism.
_Avoid_: cluster, homelab (alone), infrastructure (too broad)

**Platform Component**:
One independently-provisionable, independently-verifiable piece of the Platform (e.g.
k3s, the registry, dnsmasq, the Terraform backend, the backup mechanism). A Component
can be implemented-and-verified or planned; this document and `CLAUDE.md` track which.
_Avoid_: service, module (module is reserved for Terraform)

**Project**:
An external application or workload that deploys onto the Platform as its substrate.
HomeStreamLab is the first Project.
_Avoid_: tenant, app, application (Project is the platform-facing role; use it even
when the thing being deployed is also colloquially "an app")

**Host**:
The single physical machine the Platform runs on, identified operationally by
`HOST_LAN_IP`. All Platform Components in this milestone run on one Host; there is no
multi-node or multi-host topology.
_Avoid_: node (a k3s Node is a Kubernetes-level concept; Host is the physical machine
underneath it)

**Bootstrap**:
The ordered, host-level process of bringing the Platform's Components up from a fresh
Host to a state where a Project can be onboarded. The sequence is documented end to
end in the platform runbook (issue #10).
_Avoid_: install, setup (both used informally for a single Component; Bootstrap is the
whole ordered sequence)

**Registry Repository**:
The `<project>/<image>` path segment a Project's images are namespaced under within
the Platform's single shared container registry, distinct from the Host-specific
registry endpoint. See ADR-0003 for the full naming convention.
_Avoid_: image name (ambiguous between the repository path and a specific tag)

**Namespace Pattern**:
The reusable, parameterized Terraform module that produces a Kubernetes namespace
together with a matching ResourceQuota for a Project, generic across all Projects.
Distinct from Backup Mechanism, a separate and independently-owned concern.
_Avoid_: quota module, namespace module

**Platform Terraform Workspace**:
The single HCP Terraform workspace, named `homelab-platform`, that manages the
Platform's own Terraform-controlled resources (the Namespace Pattern module, and any
other Platform-level Terraform state). Deliberately exempt from the Project Terraform
Workspace naming convention — see ADR-0002.
_Avoid_: the Terraform workspace (ambiguous with a Project's own workspace)

**Project Terraform Workspace**:
A per-Project HCP Terraform workspace, named `<project>-k8s`, that a Project's own
repository owns to manage that Project's Kubernetes resources against this Platform.
Not created by this repository.
_Avoid_: workspace (alone, when Platform vs. Project is ambiguous)

**Backup Mechanism**:
The generic, Project-agnostic capability this Platform provides for producing and
restoring timestamped, checksummed archives of a Project's stateful data. Independent
of the Namespace Pattern; see ADR-0004 for its safety contract.
_Avoid_: backup script (one possible implementation form, not the concept)

**Backup ID**:
The caller-supplied, filesystem-safe identifier that names one backup archive. The
Backup Mechanism never infers it from context; the recommended convention is
`<project>-<workload>` (e.g. `homestreamlab-postgres`).
_Avoid_: backup name, workload name (alone)

**Recovery Target**:
The separate, explicitly named destination a restore operation writes into, distinct
from a Project's live data source. See ADR-0004 for the full restore safety contract.
_Avoid_: restore target (reads as ambiguous with "the thing being restored")
