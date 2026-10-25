# Farm fleet transport ownership

`core_fleet_farm.py` is the authoritative Farm protocol adapter used by the
personal local-CI client. It delegates to the existing protected Farm owner,
ledger and FD8 lifecycle; it does not define a scheduler or direct Docker runner.
The personal `my-core-plugs/tools/local-ci` copy is an exact-hash projection so
its existing source-injection transport remains self-contained. Update this
source first, then copy and record the matching SHA256 in client provenance.

Classic U7 transport is not yet advertised: it must use the existing classic
capacity binary/fleet lock and preserve operation identity, cancellation,
resource qualification and positive cleanup. An absent native UDS must never
fall back to uncharged host execution.
