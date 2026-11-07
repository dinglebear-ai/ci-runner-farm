# GitHub image candidates

GitHub builds create an immutable candidate tag, not a replacement for the running
fleet image. The image page reports candidate readiness. Review the log, test the
candidate separately, then run the explicit `promote-image <candidate-tag>
<image-id>` command printed by the build. Promotion checks the saved schema-2
receipt and exact Docker image ID, then tags that ID as the built-in image.
Neither building nor promotion restarts runners. GitLab builds retain their
existing direct-tag behavior.

The build context includes only the selected Dockerfile and two explicitly
requested companions: `kache-supervise.sh` and `endpoint-validation.sh`. Companion
files must be regular, non-symlink files, between 1 byte and 1 MiB. The builder
never copies the configuration directory or token files. GitHub uses
`Dockerfile.github`, then the legacy `Dockerfile`, then the packaged default.

A Dockerfile declaring `ARG KACHE_REMOTE_ENDPOINT` requires a regular mode-0600
`kache-endpoint` file. It must contain one HTTP(S) endpoint without credentials,
query, fragment, or encoded data. This is an endpoint, not a secret-token channel:
Docker build arguments can persist in image metadata. The value is passed through
the environment rather than the command line, and exact endpoint echoes are
redacted from build output. Never place an authentication token in this file.

The context hash binds the Dockerfile, companion contents and domain-separated
endpoint digest. Candidate and promoted receipts preserve the historical schema-2
format. Direct builds, async builds and promotions share one image-operation lock.
A missing local base image fails before Docker can try a remote pull.

This repair is based on deployed engine revision `e8844e5`, with the bounded
candidate protocol recovered from Tootie's `qualification-20261008` backup. It
changes no allocator, ownership ledger, cache policy or runner lifecycle.
