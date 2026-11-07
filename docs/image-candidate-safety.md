# Image candidate safety

Image builds keep the production tag unchanged until explicit promotion. The
existing saved-Dockerfile snapshot and companion-file checks remain in place.

A Dockerfile declaring `ARG KACHE_REMOTE_ENDPOINT` reads a protected endpoint
file. The endpoint is passed through the environment, not Docker's command-line
arguments, and exact endpoint echoes are redacted from build output. Userinfo,
query strings, fragments and encoded data are rejected. This is not a secret
transport: Docker build arguments may persist in image metadata. Never put
authentication credentials in the endpoint file.

Direct builds, asynchronous build workers and promotions share an image-operation
lock. Promotion validates the saved candidate and tags its exact image ID. It
stages the private promotion receipt before changing the production tag. If
receipt publication fails, it restores and verifies the previous tag, or removes
only the newly created alias when no previous tag existed. A rollback failure is
reported explicitly for operator recovery. Building and promoting do not restart
runners.

Regression coverage includes endpoint privacy, excluded credential files, unsafe
companions, immutable candidate checks, lock contention and injected promotion
receipt failures. The existing image-operation snapshot tests also remain active.
