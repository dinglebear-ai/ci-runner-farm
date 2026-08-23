# Native Phoenix plugin payloads

The Phoenix plugin consumes the two native executables that already exist in
this repository:

- `crf-scaleset`, built from `tools/crf-scaleset/cmd/crf-scaleset`
- `crf-node`, built from the Rust workspace package `crf-node`

Build both supported Linux platform trees into a new, explicit output directory:

```sh
scripts/build-native-plugin-payload.sh --output-dir build/native-plugin
```

For a local single-platform build, repeat `--platform` only for the desired
target:

```sh
scripts/build-native-plugin-payload.sh \
  --output-dir build/native-plugin-x86_64 \
  --platform linux-x86_64
```

The output uses the plugin's canonical paths:

```text
priv/bin/linux-x86_64/crf-node
priv/bin/linux-x86_64/crf-scaleset
priv/bin/linux-aarch64/crf-node
priv/bin/linux-aarch64/crf-scaleset
SHA256SUMS
provenance.json
```

The builder uses locked Rust dependencies, vendored Go dependencies, trimmed
source paths, disabled Go and ELF build IDs, `CGO_ENABLED=0`, and a fixed
`SOURCE_DATE_EPOCH` derived from the source commit unless the caller supplies
one. It validates each emitted ELF machine type before publishing the staged
directory. It refuses non-empty destinations rather than deleting caller data.

Cross-building `crf-node` for `linux-aarch64` requires the Rust
`aarch64-unknown-linux-gnu` target and an AArch64 linker. By default the builder
looks for `aarch64-linux-gnu-gcc`; set
`CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER` to select another compatible
linker. A missing target or linker is a hard failure: the output is never
reported as complete with only the Go executable present.

`SHA256SUMS` covers every executable. `provenance.json` records the exact Git
commit, project version, source epoch, platforms, paths, sizes, and SHA-256
digests. These files are build outputs and should not be committed.

Validate the builder and a real host-architecture payload with:

```sh
bash tests/native-plugin-payload.sh
```
