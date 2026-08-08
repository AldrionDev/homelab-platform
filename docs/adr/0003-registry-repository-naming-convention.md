# Registry Repository naming excludes the registry endpoint

Every Project's images live in one shared registry, namespaced as
`<project>/<image>:<tag>` (e.g. `homestreamlab/web:<tag>`). We deliberately keep the
registry endpoint (LAN IP or hostname, e.g. `<registry-endpoint>/`) out of the
convention itself — the endpoint is Host-specific and environment-dependent, while the
`<project>/<image>` path is the portable, stable part every Project references. Baking
a specific IP or `localhost:5000` into the convention would make it wrong the moment
the registry moves or is accessed from a different context (in-cluster DNS name vs.
LAN IP vs. future dnsmasq name). Alternative considered: including the endpoint as
part of a single canonical string — rejected because no single endpoint string is
valid from every calling context (Host, in-cluster, other LAN devices).
