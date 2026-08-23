# Native plugin to `crf-scaleset` contract

This document fixes the process and file boundary used when an OTP-native
plugin owns the scale-set adapter. It does not describe or alter the classic
Unraid shell runtime.

## Preflight

Before starting the sidecar, generate the complete runtime JSON as a private
regular file and invoke exactly:

```text
crf-scaleset validate-runtime --runtime-config /absolute/runtime-config.json
```

The file must be mode `0600`, no larger than 256 KiB, not a symlink, contain
one JSON value, and match runtime schema version 1. Unknown JSON fields and
trailing JSON values fail closed. Validation is local and non-mutating: it does
not open the GitHub credential, contact GitHub, create state, or open a socket.

Success is one bounded JSON line with exactly this shape:

```json
{"ok":true,"schema_version":1,"config_revision":"<64 lowercase hex>","ownership_revision":"<64 lowercase hex>","pool_count":1}
```

`pool_count` is between 1 and 8. The checked-in machine-readable golden input is
[`runtime-config-v1.json`](../../tools/crf-scaleset/cmd/crf-scaleset/testdata/runtime-config-v1.json).
The runtime file contains no credential value. Its `auth.token_file` or
`auth.private_key_file` names a separate mode-`0600` regular file that the
supervised process reads after preflight.

## Supervision

After preflight and compatibility-record selection, start exactly one process
with an argument array (never through a shell):

```text
crf-scaleset supervise \
  --socket /absolute/private-runtime-dir/control.sock \
  --compatibility /absolute/compatibility.json \
  --runtime-config /absolute/runtime-config.json
```

All three values are required, absolute paths supplied as individual argv
elements. No configuration or secret is accepted through environment variables
or command-line values. The compatibility record is a mode-`0600`, bounded,
sealed record produced by `probe`; supervision requires its owner, installation,
host, runner-group, plugin, image, Dockerfile, and entrypoint identities to
match the runtime configuration before opening the socket.

The socket parent is created or accepted only as an effective-UID-owned mode
`0700` directory. The socket is mode `0600`. Existing non-socket paths,
unowned sockets, symlinked runtime directories, and peers with a different
effective UID fail closed. SIGTERM is the normal shutdown signal; the server
removes only the same socket inode it created.

## Requests

The plugin sends one schema-v1 JSON request per Unix connection. The fixed CLI
bridge for diagnostics is:

```text
crf-scaleset request --socket /absolute/private-runtime-dir/control.sock --timeout 120s
```

The request is supplied on standard input, never argv. Input and response are
bounded to 1 MiB; request payload is bounded to 512 KiB; timeout must be greater
than zero and no more than two minutes. Required envelope fields are
`schema_version`, `request_id`, `operation`, `config_revision`,
`ownership_revision`, `controller_instance_id`, `sequence`, and `payload`.
Unknown fields and trailing JSON fail closed. Sequence is strictly increasing
per controller identity and must be durably advanced by the plugin before the
socket write.

The operation allowlist is `apply_sessions`, `publish_capacity_leases`,
`issue_jit`, `retire_jit`, `read_snapshot`, `read_jit_state`,
`reconcile_owned`, and `delete_owned`. A response is one schema-v1 JSON object
correlated by `request_id`. The diagnostic CLI exits `0` for `ok: true`, `2`
for a typed `ok: false` response, and nonzero for transport or validation
failure.
