# Use `homelab.home.arpa` as the canonical platform DNS domain

The Platform's wildcard DNS component (dnsmasq, issue #5) needs a domain suffix under
which every home-lab service resolves on the LAN. The domain previously placeholdered
in `.env.example` and `CLAUDE.md` was `homelab.local`; we reject that in favor of
`homelab.home.arpa`.

`.local` is not a free-form suffix available for private unicast DNS: RFC 6762
("Multicast DNS") reserves the entire `.local` namespace for mDNS, and resolvers that
implement it are specified to resolve `.local`-suffixed names via multicast rather than
as ordinary unicast queries. Read-only inspection of this repository's reference host
confirms the relevant machinery is active, not merely theoretical: systemd-resolved is
the running resolver, and `resolvectl status` shows the `mDNS` protocol enabled on the
default-route link. Under that observed configuration, `.local`-suffixed queries are
subject to mDNS handling on this host rather than guaranteed to reach a unicast
resolver such as dnsmasq — a dnsmasq server answering unicast queries for
`*.homelab.local` would compete with the namespace's actual reserved purpose. Apple's
own developer documentation similarly describes `.local` as reserved for Bonjour/mDNS
and advises against using it for other purposes on their platforms; we cite that as
directional support without asserting a more specific behavioral claim than it makes.

RFC 8375 ("Special-Use Domain 'home.arpa.'") exists specifically to give residential
home networks a domain suffix for this purpose — internal, unicast, locally-resolved
naming — without the `.local` collision. Adopting `home.arpa` as the platform's root
and keeping the existing `homelab` label as a sub-domain of it (`homelab.home.arpa`)
removes the namespace conflict at its source. Documenting the `.local` interoperability
limitation and leaving `*.homelab.local` in place was considered and rejected: RFC
6762's reservation does not change no matter how the limitation is written up, so the
correct fix is not to use `.local` for this purpose at all.

Rejected alternative: `homelab.local` — rejected because it is the mDNS special-use
namespace per RFC 6762, not because of any implementation defect in dnsmasq or this
platform.

Existing ignored local `.env` files that still set `HOMELAB_DOMAIN=homelab.local` must
be updated manually; this decision does not create or modify `.env`.
