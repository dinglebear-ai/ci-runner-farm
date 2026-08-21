# Certificate lifecycle

CRF separates TLS trust from runner authorization. The CA bundle proves that a certificate chains to an accepted issuer. The controller `tls.peers` map separately authorizes the SHA-256 fingerprint of one exact client certificate for one `node_id`. A CA-signed certificate is not a runner node until its fingerprint is allowed.

CRF is deliberately CA-agnostic. Use an offline/internal CA, Vault PKI, step-ca, enterprise PKI, or another controlled issuer. CRF owns fingerprint authorization and live revocation, not private-key issuance.

## Fingerprints

The Linux bundle includes `crf-cert-fingerprint <certificate.pem>`. It outputs lowercase SHA-256 of the certificate DER bytes with no colons, exactly matching `tls.peers[].fingerprint`. The helper accepts only a regular non-symlink PEM file.

## Initial enrollment

1. Issue a unique client certificate/key for the node from a CA present in the controller trust bundle. Use client-auth EKU when supported.
2. Compute the leaf fingerprint with `crf-cert-fingerprint`.
3. Add the fingerprint and intended `node_id` to `tls.peers` in the private controller config.
4. Reload the controller authorization set with `systemctl reload ci-runner-farm-controller`.
5. Install the CA/client certificate/private key on the node and start the node service.
6. Verify the expected node identity, generation, and heartbeat.

Initial controller boot still requires a non-empty peer allowlist.

## Leaf rotation without controller restart

Use overlap, not a flag day:

1. Issue the replacement client certificate/key and compute its fingerprint.
2. Add the new fingerprint **alongside** the old fingerprint, both mapped to the same node ID.
3. Run `systemctl reload ci-runner-farm-controller`.
4. Replace the node leaf/key atomically and restart only the node agent. Runner children are intentionally not killed by an agent restart.
5. Verify the node reconnects on the expected new generation.
6. Remove the old fingerprint from `controller.json` and reload again.

Multiple fingerprints may map to one node during rotation. One fingerprint may not map to multiple node IDs.

## Normal revocation

Remove the fingerprint from `controller.json` and run `systemctl reload ci-runner-farm-controller`. Reload parses and validates the complete replacement allowlist before changing active state, so malformed updates leave the previous revision intact.

The active `PeerRegistry` is consulted before **every framed message**, not only at the TLS handshake. An already-connected node whose fingerprint is removed is therefore closed on its next frame. A live TLS 1.3 integration test proves this by registering a node, revoking its fingerprint without closing the client socket, sending another heartbeat, and observing the server close the session.

## Emergency revoke-all

Use only when immediate denial is more important than first editing the config:

`sudo -u ci-runner-farm /opt/ci-runner-farm/current/bin/crf-peer-admin revoke-all --force`

Inspect live state with:

`sudo -u ci-runner-farm /opt/ci-runner-farm/current/bin/crf-peer-admin status`

Emergency revoke-all is in-memory and intentionally **not persistent**. A restart or later reload restores whatever the config declares. Update the config immediately after an emergency revocation.

## CA and server-certificate rotation

CA trust is loaded into TLS endpoints at initialization, so CA-bundle and controller server-certificate changes still use a phased restart:

1. Distribute trust bundles containing old + new CA material where appropriate.
2. Restart endpoints to load the dual trust set.
3. Rotate node leaves with fingerprint overlap.
4. Rotate the controller server leaf and restart the controller listener.
5. Verify all nodes reconnect through the new chain.
6. Remove old CA material and restart endpoints again.

Do not remove the old trust root before all required leaves/server certificates have migrated.

## Revocation model

CRF currently uses CA validation plus exact leaf-fingerprint authorization rather than implementing its own CRL/OCSP service. Removing a fingerprint revokes that node at the CRF authorization layer even if its CA-issued certificate remains cryptographically valid. If your PKI publishes CRL/OCSP, enforce it through the PKI/network policy as appropriate.

Treat CA bundles, server/node private keys, `tls.peers`, and emergency revoke-all as security-sensitive changes. Record issuer/serial/fingerprint, node ID, issue/expiry time, rotation reason, and change/operator reference in the deployment audit trail. Never log private keys or JIT material.
