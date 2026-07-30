# Deterministic test fixtures

Fixtures in this directory are synthetic and must not contain live GitHub,
Docker, runner, or host data. Tests should use `mktemp -d`, fake time, and the
helpers under `tests/lib` so the suite never mutates `/boot`, Docker, GitHub, or
the configured runner cache.
