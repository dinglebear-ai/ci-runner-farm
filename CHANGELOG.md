# Changelog

## Unreleased

### Changed

* Build local runner images under immutable candidate tags and require an explicit exact-image-ID promotion before changing the production `ci-runner-farm-runner:latest` tag.
* Add persistent mutation-owner leases that fence competing UI, CLI, reconcile, recycle, and daemon mutations across multi-command maintenance sessions.
* Reject V2 configured baselines that exceed post-reserve CPU or memory admission budgets, using fixed capacity for fixed pools and minimum capacity for autoscaled pools, and expose configured claims plus remaining headroom in status JSON.
* Add an idempotent Tootie fleet-audit installer and daily 06:30 audit covering exact GitHub identities and labels, runner image and Kache integrity, plugin identity, resource headroom, reconciliation state, watchdog stability, and Unraid/Gotify pass-fail notifications.
* Make the package reproducibility assertion deterministic under `pipefail` by fully extracting the inspected file before searching it.

* Move the canonical repository and scale-set helper module identity to `dinglebear-ai/ci-runner-farm`.
* Route trusted dinglebear-ai CI through the `ci-pool-ops` self-hosted pool while keeping public fork pull requests on GitHub-hosted runners.
* Include PHP CLI, ripgrep, and file inspection tools in the Tootie runner image so the repository's syntax, behavioral, and release gates run on the farm.
* Make the watchdog process-enumeration regression test independent of host PID ordering.
* Replace the temporary Kache prefetch backport with the checksum-pinned upstream v0.13.0 release across the Tootie runner image profile, layering the rollout on the current s3-v8 Kache/CC image.
* Document the final feasible 16-runner Tootie pool envelope with six Rust and one Python runner, and require pristine-image Kache version and checksum verification before fleet reconciliation.
* Continue stale-runner reconciliation after a graceful recycle is safely refused, allowing later idle stale runners to migrate without waiting behind a transiently misreported busy runner.

## [1.9.0](https://github.com/dinglebear-ai/ci-runner-farm/compare/v1.8.1...v1.9.0) (2026-08-05)


### Features

* harden fleet change control ([5d9b02d](https://github.com/dinglebear-ai/ci-runner-farm/commit/5d9b02d6dff7c6ff7565be4ccf97bd362886c242))
* harden fleet change control ([08c06e7](https://github.com/dinglebear-ai/ci-runner-farm/commit/08c06e760752addcf11e23330ba5dddf2cf7fb87))


### Bug Fixes

* **cache:** keep Cargo registries runner-local ([#23](https://github.com/dinglebear-ai/ci-runner-farm/issues/23)) ([2769fb0](https://github.com/dinglebear-ai/ci-runner-farm/commit/2769fb0f6277b1295eca134ed1d38e7d37caea1a))
* **pools:** close lifecycle and readiness gaps ([a1410e1](https://github.com/dinglebear-ai/ci-runner-farm/commit/a1410e100c394e2ae49ac02d18ec9bb7a792d362))
* **pools:** harden pool config validation against overflow and race conditions ([59f8349](https://github.com/dinglebear-ai/ci-runner-farm/commit/59f834943f4022673869528f838a8d1443133dab))
* **queue:** recognize routed jobs and sample repos fairly ([#25](https://github.com/dinglebear-ai/ci-runner-farm/issues/25)) ([39bcf4c](https://github.com/dinglebear-ai/ci-runner-farm/commit/39bcf4ca375d3699efa5c408192addeb7ea98f32))
* recover runners stalled at credential handoff ([86c31c2](https://github.com/dinglebear-ai/ci-runner-farm/commit/86c31c29f30391a9d0d5090f28b8491d1356486e))
* **runner:** restart dockerd through sudo, not as the runner user ([#21](https://github.com/dinglebear-ai/ci-runner-farm/issues/21)) ([3869bd5](https://github.com/dinglebear-ai/ci-runner-farm/commit/3869bd5f4655b7c00a48dfc05b673ba0e6a40f6c))
* **runners:** recover stalled credential handoffs ([2c1baa8](https://github.com/dinglebear-ai/ci-runner-farm/commit/2c1baa8a271b1c7b470735464604e0bea2df68d1))
* **tests:** give the scale-set helper room to start before the deadline ([9570343](https://github.com/dinglebear-ai/ci-runner-farm/commit/95703437b4d317efe6851576d4fdd1a1b255b6c9))
* **tests:** give the scale-set helper room to start before the deadline ([5b26296](https://github.com/dinglebear-ai/ci-runner-farm/commit/5b26296d6060863a0049ed957766113375b3b6b0))

## [1.8.1](https://github.com/dinglebear-ai/ci-runner-farm/compare/v1.8.0...v1.8.1) (2026-08-05)


### Bug Fixes

* **reconcile:** skip refused stale runners ([#15](https://github.com/dinglebear-ai/ci-runner-farm/issues/15)) ([ee4ccc7](https://github.com/dinglebear-ai/ci-runner-farm/commit/ee4ccc7f9a3cfa411f5b4ce1352759ba04053fd1))
* **ui:** preserve Unraid chrome with framed app shell ([3df3af0](https://github.com/dinglebear-ai/ci-runner-farm/commit/3df3af0bc46f30a801942fb7b4e458af426c29d1))

## [1.8.0](https://github.com/dinglebear-ai/ci-runner-farm/compare/v1.7.0...v1.8.0) (2026-08-04)


### Features

* add routed runner pools ([13e86bb](https://github.com/dinglebear-ai/ci-runner-farm/commit/13e86bb78bfe093e2f3b81f30b1ef69021bd8354))
* **default-image:** add runner HEALTHCHECK to the shipped starter Dockerfile ([#27](https://github.com/dinglebear-ai/ci-runner-farm/issues/27)) ([ea6c88d](https://github.com/dinglebear-ai/ci-runner-farm/commit/ea6c88d0cbb9e8f683610d2c7bd632224fa13367))
* DinD mode (own dockerd per runner) to fix services: networking + port collisions ([74990ff](https://github.com/dinglebear-ai/ci-runner-farm/commit/74990ff76a3dc205e973de3f9364e679a04db748))
* **dind:** bind per-runner diagnostics dir for DinD post-mortem ([#12](https://github.com/dinglebear-ai/ci-runner-farm/issues/12)) ([9f63027](https://github.com/dinglebear-ai/ci-runner-farm/commit/9f63027052c2f00305e171feba634228e6b2af21))
* fat runner image (warm caches) + graceful stop + package cache ([88f6ce0](https://github.com/dinglebear-ai/ci-runner-farm/commit/88f6ce0679b72ade9cdf7d0109da4d333df58e90))
* field tooltips + pre-scoped GitHub PAT link; harden deploys to root:root ([e320ca6](https://github.com/dinglebear-ai/ci-runner-farm/commit/e320ca67c7fc5ecdcb69a7e6d36177e7e1844488))
* fleet hardening, Main dashboard widget, live config migration ([#40](https://github.com/dinglebear-ai/ci-runner-farm/issues/40)) ([e74875b](https://github.com/dinglebear-ai/ci-runner-farm/commit/e74875b414f4f0149fea021bc6196045ae771861))
* generic starter runner image + bring-your-own-image ([d6bcf90](https://github.com/dinglebear-ai/ci-runner-farm/commit/d6bcf9076fa34d1313886f0a23f7155e3f509754))
* image source selector (built-in vs remote) ([193ec88](https://github.com/dinglebear-ai/ci-runner-farm/commit/193ec887f819d28559fc81b677e8dc9b1c36b99e))
* in-plugin runner image builder (editable Dockerfile + Build button) ([a996fda](https://github.com/dinglebear-ai/ci-runner-farm/commit/a996fda19b280d636a1a95561906e7a36074aa62))
* **kache:** deploy no-prefetch persistent runner profile ([#8](https://github.com/dinglebear-ai/ci-runner-farm/issues/8)) ([d69a965](https://github.com/dinglebear-ai/ci-runner-farm/commit/d69a965f325e8cbe3ef7000ef703d0a7eca32996))
* private registry docker login + configurable cache mounts ([87e62c4](https://github.com/dinglebear-ai/ci-runner-farm/commit/87e62c4d4dc958871dfc008c7cb1e1b2bb0a044e))
* proper Plugins-page name + icon link to settings ([#8](https://github.com/dinglebear-ai/ci-runner-farm/issues/8)) ([7f71781](https://github.com/dinglebear-ai/ci-runner-farm/commit/7f71781fdd4b91a0277246c541e621d1991d8806))
* public-release publishing via release-please + GitHub artifacts ([#1](https://github.com/dinglebear-ai/ci-runner-farm/issues/1)) ([46eb8c1](https://github.com/dinglebear-ai/ci-runner-farm/commit/46eb8c178a61c256044bea5f689622828c62be8f))
* queue-aware autoscaler with tuning options ([f19cd16](https://github.com/dinglebear-ai/ci-runner-farm/commit/f19cd16c7ab1fc04d81ccf62b5069d22a7273486))
* **registry:** reuse GitHub PAT for GHCR login when no registry token set ([60d41db](https://github.com/dinglebear-ai/ci-runner-farm/commit/60d41dbf6d5c56b872cb8db37f2b70be23ce28f4))
* restart the fleet on Unraid Docker stop/start events ([#11](https://github.com/dinglebear-ai/ci-runner-farm/issues/11)) ([6596c41](https://github.com/dinglebear-ai/ci-runner-farm/commit/6596c4147ed3423d8a5774c521e819f4d8c81e7b))
* run jobs as non-root by default with GitHub-hosted storage parity ([#5](https://github.com/dinglebear-ai/ci-runner-farm/issues/5)) ([159384e](https://github.com/dinglebear-ai/ci-runner-farm/commit/159384e4dce37efb739703ed7eb13441f35aa4b1))
* **runner-image:** add Rust build preset ([#2](https://github.com/dinglebear-ai/ci-runner-farm/issues/2)) ([336d839](https://github.com/dinglebear-ai/ci-runner-farm/commit/336d839ad123f0ee10aeaa765297878103cf026a))
* scheduled runner-image auto-update with drain-then-recreate ([#9](https://github.com/dinglebear-ai/ci-runner-farm/issues/9)) ([3ddaccc](https://github.com/dinglebear-ai/ci-runner-farm/commit/3ddaccc508994871e8a6556e5fc06576499a4507))
* **security:** harden defaults for public Community Apps distribution ([#15](https://github.com/dinglebear-ai/ci-runner-farm/issues/15)) ([62b9df8](https://github.com/dinglebear-ai/ci-runner-farm/commit/62b9df8f7f3f9ffa57b5c41b03c0cb86a91bfa16))
* shared image cache (registry mirror) + guard CACHE_ROOT against rootfs ([5aa92d9](https://github.com/dinglebear-ai/ci-runner-farm/commit/5aa92d9261d7308eae78e06eb365b1416d2b5a2c))
* support manual autoscale burst capacity ([4fc03d9](https://github.com/dinglebear-ai/ci-runner-farm/commit/4fc03d901ce133b32fc57699e52bde8fae2ba08f))
* **ui:** hide remote-only fields unless Image source = Remote ([55e58c3](https://github.com/dinglebear-ai/ci-runner-farm/commit/55e58c36cb02014bde2526e861e205d59d33248e))
* **ui:** native folder picker on Cache root path field ([4253c75](https://github.com/dinglebear-ai/ci-runner-farm/commit/4253c75523c6f198caab987285c60cba5d8b8570))
* **ui:** settings-page facelift — tabbed fleet hub, image builder, cache/stats, native theming ([#33](https://github.com/dinglebear-ai/ci-runner-farm/issues/33)) ([fc95b61](https://github.com/dinglebear-ai/ci-runner-farm/commit/fc95b614c61dc8dca99c68358e67ea428c4a0297))
* **ui:** ship polished responsive runner farm interface ([9585786](https://github.com/dinglebear-ai/ci-runner-farm/commit/9585786c7d62364dbc9a425cb70673a6da376f9b))


### Bug Fixes

* accept empty ineligible handle snapshots ([3b70aa9](https://github.com/dinglebear-ai/ci-runner-farm/commit/3b70aa94f13aaabe9acfb6bc2a06c43af7263207))
* address runner pool review findings ([a6de246](https://github.com/dinglebear-ai/ci-runner-farm/commit/a6de246d99f0a4003235c8263e5ad5bfb8eb637a))
* **autoscale:** reap disconnected (health=unhealthy) runners, not just exited ([#25](https://github.com/dinglebear-ai/ci-runner-farm/issues/25)) ([727e4e2](https://github.com/dinglebear-ai/ci-runner-farm/commit/727e4e2ed0aaf5753f40c82e64e586c5bb7cd1b3))
* bound scale-set request I/O ([f53ef4e](https://github.com/dinglebear-ai/ci-runner-farm/commit/f53ef4e6284f412349e80db945c241eeacbc08c9))
* cache runner config identity per operation ([7326b59](https://github.com/dinglebear-ai/ci-runner-farm/commit/7326b59db0a215b1c19f97638b8ea7d7a122e1bb))
* **ci:** keep overlay toolchain rebuildable ([2931636](https://github.com/dinglebear-ai/ci-runner-farm/commit/2931636086296346f0080107816d73709ac258ae))
* **ci:** provision PHP on ops runners ([9494ea3](https://github.com/dinglebear-ai/ci-runner-farm/commit/9494ea3dd6ab69a1e86d94f2a567aa22ee64fe27))
* **ci:** provision regression test tools ([f69cbad](https://github.com/dinglebear-ai/ci-runner-farm/commit/f69cbad22ad1fb39d81409273d673c8446113f04))
* **ci:** route same-repo PRs to the farm ([049b761](https://github.com/dinglebear-ai/ci-runner-farm/commit/049b76183285f43484c95ee29b9f2dc4544f1da0))
* close runner control-plane review gaps ([9d7cec5](https://github.com/dinglebear-ai/ci-runner-farm/commit/9d7cec5bf722cbd86e2283ace713305ac5877874))
* complete runner-farm control-plane hardening ([e1d6584](https://github.com/dinglebear-ai/ci-runner-farm/commit/e1d6584ab590c707a26039f59d3f6b55bbeba3cb))
* **dind:** real-FS Docker data root for runners + FUSE cache-root guard/warning ([#7](https://github.com/dinglebear-ai/ci-runner-farm/issues/7)) ([1f06c8e](https://github.com/dinglebear-ai/ci-runner-farm/commit/1f06c8e508d0c537b16e08a91bf773beeb61b9c3))
* hand off recycle registration credential ([3e60378](https://github.com/dinglebear-ai/ci-runner-farm/commit/3e60378a1407a817b3cd0dd14e72584eba084de6))
* harden live pool reconciliation ([ede72cd](https://github.com/dinglebear-ai/ci-runner-farm/commit/ede72cd282682ed1142bfe56b693e5970a0e39a6))
* harden runner reconciliation identity ([f480dcd](https://github.com/dinglebear-ai/ci-runner-farm/commit/f480dcdd7d9d90d01806bf69fc4c102cd8b491cd))
* harden runner recycle cleanup ([bc7fec3](https://github.com/dinglebear-ai/ci-runner-farm/commit/bc7fec3d9051e90f367dc31d9dba0661c3466b11))
* honor EPHEMERAL=false, enforce autoscale MIN floor, runner-owned cache dirs ([#30](https://github.com/dinglebear-ai/ci-runner-farm/issues/30)) ([a605b80](https://github.com/dinglebear-ai/ci-runner-farm/commit/a605b80193cd93ba37ee9849c8ea52ba3110cd45))
* inspect recorded recycle image argument ([51f2628](https://github.com/dinglebear-ai/ci-runner-farm/commit/51f2628b8e8dce5a55b2417f831d6fbf8f039dc7))
* **kache:** preserve current overlay base ([#13](https://github.com/dinglebear-ai/ci-runner-farm/issues/13)) ([8a78d77](https://github.com/dinglebear-ai/ci-runner-farm/commit/8a78d77fec46a3514977f2e0b6ca8ecaee60dd79))
* land stranded review fixes and release public CA readiness (1.5.0) ([#19](https://github.com/dinglebear-ai/ci-runner-farm/issues/19)) ([5acc848](https://github.com/dinglebear-ai/ci-runner-farm/commit/5acc8484fdfc08a399a8d315eadf1d999408c2ee))
* make autoscale recovery idempotent ([f6a0a19](https://github.com/dinglebear-ai/ci-runner-farm/commit/f6a0a19602ba0f45fca64c9f890633dc01efbbd0))
* **plugin:** dedicated .tgz package + Unraid config idioms ([#23](https://github.com/dinglebear-ai/ci-runner-farm/issues/23)) ([97873dc](https://github.com/dinglebear-ai/ci-runner-farm/commit/97873dc377e2bea6a46af95f976e45951f17b880))
* prove drain with stopped supervisor ([67239c6](https://github.com/dinglebear-ai/ci-runner-farm/commit/67239c67ed04b5eb5ef231e1823066f1a609c2a3))
* prove ineligible scale-set drain ([9c05345](https://github.com/dinglebear-ai/ci-runner-farm/commit/9c05345d09db3c8ab64ef5bd8991201fc45ba17f))
* recreate runners with a fresh token instead of resurrecting stale ones ([#22](https://github.com/dinglebear-ai/ci-runner-farm/issues/22)) ([411d5cd](https://github.com/dinglebear-ai/ci-runner-farm/commit/411d5cd5f24f6602684df8d60148d2807da1d4a2))
* release scale-set request lock after timeout ([3d124ff](https://github.com/dinglebear-ai/ci-runner-farm/commit/3d124ffc002feed9209f4abd7c0a28b844a77488))
* **release:** credit commit authors in notes ([#35](https://github.com/dinglebear-ai/ci-runner-farm/issues/35)) ([7307817](https://github.com/dinglebear-ai/ci-runner-farm/commit/73078170d2156559b928b30d86e9bf677f857bda))
* **release:** update release-please action ([#38](https://github.com/dinglebear-ai/ci-runner-farm/issues/38)) ([4a33381](https://github.com/dinglebear-ai/ci-runner-farm/commit/4a333817291f452a9cb46ea7782334cdca0054d0))
* restore missing runner Kache supervisors ([#6](https://github.com/dinglebear-ai/ci-runner-farm/issues/6)) ([dbbd08b](https://github.com/dinglebear-ai/ci-runner-farm/commit/dbbd08b5ead304b2436d79ee74d7da9989a4376c))
* scope install extraction to plugin dir, force root perms ([bb869cc](https://github.com/dinglebear-ai/ci-runner-farm/commit/bb869cc7ee266d55795c5b59ade4044a752679cf))
* show active jobs for busy runners ([38b3168](https://github.com/dinglebear-ai/ci-runner-farm/commit/38b316808a93621e5c716fe870a6499d7d198b5f))
* surface scale-set job activity ([5eddb43](https://github.com/dinglebear-ai/ci-runner-farm/commit/5eddb435f9fb55d4befea310d0153faf9afeef49))
* **tests:** normalize watchdog PID ordering ([10d76a8](https://github.com/dinglebear-ai/ci-runner-farm/commit/10d76a8be2cf9c4d3db67fc178443a114ae25d3b))
* **tests:** normalize watchdog PID ordering ([da5b9f8](https://github.com/dinglebear-ai/ci-runner-farm/commit/da5b9f8950dbe5891937b380a3e9a08a84757a1b))
* **ui:** keep the fleet log panel visible when empty ([#4](https://github.com/dinglebear-ai/ci-runner-farm/issues/4)) ([79e032d](https://github.com/dinglebear-ai/ci-runner-farm/commit/79e032d13bf92a2bd30ca4e1c49b9d1417d522a3))
* **ui:** load jquery.filetree js+css so the Cache root picker actually works ([e352946](https://github.com/dinglebear-ai/ci-runner-farm/commit/e352946d43197d5ab2be8dc69585abe8642ca0ac))
* **ui:** use Unraid native inline help (markdown form + :plug:/&gt;/:end) ([43c52b3](https://github.com/dinglebear-ai/ci-runner-farm/commit/43c52b323d6ed58a6bee813eae7b24b72a1f208f))


### Performance Improvements

* **kache:** cache fmerge-all-constants C builds ([17798ec](https://github.com/dinglebear-ai/ci-runner-farm/commit/17798eca1aa82a7c1e65aabc0e64a8c2fb6ea16c))

## [1.7.0](https://github.com/unraid/ci-runner-farm/compare/v1.6.0...v1.7.0) (2026-07-24)


### Features

* fleet hardening, Main dashboard widget, live config migration ([#40](https://github.com/unraid/ci-runner-farm/issues/40)) ([e74875b](https://github.com/unraid/ci-runner-farm/commit/e74875b414f4f0149fea021bc6196045ae771861))

## [1.6.0](https://github.com/unraid/ci-runner-farm/compare/v1.5.1...v1.6.0) (2026-07-22)


### Features

* **ui:** settings-page facelift — tabbed fleet hub, image builder, cache/stats, native theming (@jmagar) ([#33](https://github.com/unraid/ci-runner-farm/issues/33)) ([fc95b61](https://github.com/unraid/ci-runner-farm/commit/fc95b614c61dc8dca99c68358e67ea428c4a0297))


### Bug Fixes

* **release:** credit commit authors in notes ([#35](https://github.com/unraid/ci-runner-farm/issues/35)) ([7307817](https://github.com/unraid/ci-runner-farm/commit/73078170d2156559b928b30d86e9bf677f857bda))
* **release:** update release-please action ([#38](https://github.com/unraid/ci-runner-farm/issues/38)) ([4a33381](https://github.com/unraid/ci-runner-farm/commit/4a333817291f452a9cb46ea7782334cdca0054d0))

## [1.5.1](https://github.com/unraid/ci-runner-farm/compare/v1.5.0...v1.5.1) (2026-07-22)


### Bug Fixes

* honor EPHEMERAL=false, enforce autoscale MIN floor, runner-owned cache dirs ([#30](https://github.com/unraid/ci-runner-farm/issues/30)) ([a605b80](https://github.com/unraid/ci-runner-farm/commit/a605b80193cd93ba37ee9849c8ea52ba3110cd45))

## [1.5.0](https://github.com/unraid/ci-runner-farm/compare/v1.4.3...v1.5.0) (2026-07-12)


### Features

* **default-image:** add runner HEALTHCHECK to the shipped starter Dockerfile ([#27](https://github.com/unraid/ci-runner-farm/issues/27)) ([ea6c88d](https://github.com/unraid/ci-runner-farm/commit/ea6c88d0cbb9e8f683610d2c7bd632224fa13367))

## [1.4.3](https://github.com/unraid/ci-runner-farm/compare/v1.4.2...v1.4.3) (2026-07-12)


### Bug Fixes

* **autoscale:** reap disconnected (health=unhealthy) runners, not just exited ([#25](https://github.com/unraid/ci-runner-farm/issues/25)) ([727e4e2](https://github.com/unraid/ci-runner-farm/commit/727e4e2ed0aaf5753f40c82e64e586c5bb7cd1b3))

## [1.4.2](https://github.com/unraid/ci-runner-farm/compare/v1.4.1...v1.4.2) (2026-07-07)


### Bug Fixes

* **plugin:** dedicated .tgz package + Unraid config idioms ([#23](https://github.com/unraid/ci-runner-farm/issues/23)) ([97873dc](https://github.com/unraid/ci-runner-farm/commit/97873dc377e2bea6a46af95f976e45951f17b880))
* recreate runners with a fresh token instead of resurrecting stale ones ([#22](https://github.com/unraid/ci-runner-farm/issues/22)) ([411d5cd](https://github.com/unraid/ci-runner-farm/commit/411d5cd5f24f6602684df8d60148d2807da1d4a2))

## [1.4.1](https://github.com/unraid/ci-runner-farm/compare/v1.4.0...v1.4.1) (2026-07-07)


### Bug Fixes

* land stranded review fixes and release public CA readiness (1.5.0) ([#19](https://github.com/unraid/ci-runner-farm/issues/19)) ([5acc848](https://github.com/unraid/ci-runner-farm/commit/5acc8484fdfc08a399a8d315eadf1d999408c2ee))

## [1.4.0](https://github.com/unraid/ci-runner-farm/compare/v1.3.0...v1.4.0) (2026-07-01)


### Features

* **security:** harden defaults for public Community Apps distribution ([#15](https://github.com/unraid/ci-runner-farm/issues/15)) ([62b9df8](https://github.com/unraid/ci-runner-farm/commit/62b9df8f7f3f9ffa57b5c41b03c0cb86a91bfa16))

## [1.3.0](https://github.com/unraid/ci-runner-farm/compare/v1.2.0...v1.3.0) (2026-06-30)


### Features

* **dind:** bind per-runner diagnostics dir for DinD post-mortem ([#12](https://github.com/unraid/ci-runner-farm/issues/12)) ([9f63027](https://github.com/unraid/ci-runner-farm/commit/9f63027052c2f00305e171feba634228e6b2af21))
* restart the fleet on Unraid Docker stop/start events ([#11](https://github.com/unraid/ci-runner-farm/issues/11)) ([6596c41](https://github.com/unraid/ci-runner-farm/commit/6596c4147ed3423d8a5774c521e819f4d8c81e7b))

## [1.2.0](https://github.com/unraid/ci-runner-farm/compare/v1.1.0...v1.2.0) (2026-06-26)


### Features

* scheduled runner-image auto-update with drain-then-recreate ([#9](https://github.com/unraid/ci-runner-farm/issues/9)) ([3ddaccc](https://github.com/unraid/ci-runner-farm/commit/3ddaccc508994871e8a6556e5fc06576499a4507))

## [1.1.0](https://github.com/unraid/ci-runner-farm/compare/v1.0.0...v1.1.0) (2026-06-24)


### Features

* proper Plugins-page name + icon link to settings ([#8](https://github.com/unraid/ci-runner-farm/issues/8)) ([7f71781](https://github.com/unraid/ci-runner-farm/commit/7f71781fdd4b91a0277246c541e621d1991d8806))
* run jobs as non-root by default with GitHub-hosted storage parity ([#5](https://github.com/unraid/ci-runner-farm/issues/5)) ([159384e](https://github.com/unraid/ci-runner-farm/commit/159384e4dce37efb739703ed7eb13441f35aa4b1))


### Bug Fixes

* **dind:** real-FS Docker data root for runners + FUSE cache-root guard/warning ([#7](https://github.com/unraid/ci-runner-farm/issues/7)) ([1f06c8e](https://github.com/unraid/ci-runner-farm/commit/1f06c8e508d0c537b16e08a91bf773beeb61b9c3))
* **ui:** keep the fleet log panel visible when empty ([#4](https://github.com/unraid/ci-runner-farm/issues/4)) ([79e032d](https://github.com/unraid/ci-runner-farm/commit/79e032d13bf92a2bd30ca4e1c49b9d1417d522a3))

## 1.0.0 (2026-06-24)


### Features

* DinD mode (own dockerd per runner) to fix services: networking + port collisions ([74990ff](https://github.com/unraid/ci-runner-farm/commit/74990ff76a3dc205e973de3f9364e679a04db748))
* fat runner image (warm caches) + graceful stop + package cache ([88f6ce0](https://github.com/unraid/ci-runner-farm/commit/88f6ce0679b72ade9cdf7d0109da4d333df58e90))
* field tooltips + pre-scoped GitHub PAT link; harden deploys to root:root ([e320ca6](https://github.com/unraid/ci-runner-farm/commit/e320ca67c7fc5ecdcb69a7e6d36177e7e1844488))
* generic starter runner image + bring-your-own-image ([d6bcf90](https://github.com/unraid/ci-runner-farm/commit/d6bcf9076fa34d1313886f0a23f7155e3f509754))
* image source selector (built-in vs remote) ([193ec88](https://github.com/unraid/ci-runner-farm/commit/193ec887f819d28559fc81b677e8dc9b1c36b99e))
* in-plugin runner image builder (editable Dockerfile + Build button) ([a996fda](https://github.com/unraid/ci-runner-farm/commit/a996fda19b280d636a1a95561906e7a36074aa62))
* private registry docker login + configurable cache mounts ([87e62c4](https://github.com/unraid/ci-runner-farm/commit/87e62c4d4dc958871dfc008c7cb1e1b2bb0a044e))
* public-release publishing via release-please + GitHub artifacts ([#1](https://github.com/unraid/ci-runner-farm/issues/1)) ([46eb8c1](https://github.com/unraid/ci-runner-farm/commit/46eb8c178a61c256044bea5f689622828c62be8f))
* queue-aware autoscaler with tuning options ([f19cd16](https://github.com/unraid/ci-runner-farm/commit/f19cd16c7ab1fc04d81ccf62b5069d22a7273486))
* **registry:** reuse GitHub PAT for GHCR login when no registry token set ([60d41db](https://github.com/unraid/ci-runner-farm/commit/60d41dbf6d5c56b872cb8db37f2b70be23ce28f4))
* shared image cache (registry mirror) + guard CACHE_ROOT against rootfs ([5aa92d9](https://github.com/unraid/ci-runner-farm/commit/5aa92d9261d7308eae78e06eb365b1416d2b5a2c))
* **ui:** hide remote-only fields unless Image source = Remote ([55e58c3](https://github.com/unraid/ci-runner-farm/commit/55e58c36cb02014bde2526e861e205d59d33248e))
* **ui:** native folder picker on Cache root path field ([4253c75](https://github.com/unraid/ci-runner-farm/commit/4253c75523c6f198caab987285c60cba5d8b8570))


### Bug Fixes

* scope install extraction to plugin dir, force root perms ([bb869cc](https://github.com/unraid/ci-runner-farm/commit/bb869cc7ee266d55795c5b59ade4044a752679cf))
* **ui:** load jquery.filetree js+css so the Cache root picker actually works ([e352946](https://github.com/unraid/ci-runner-farm/commit/e352946d43197d5ab2be8dc69585abe8642ca0ac))
* **ui:** use Unraid native inline help (markdown form + :plug:/&gt;/:end) ([43c52b3](https://github.com/unraid/ci-runner-farm/commit/43c52b323d6ed58a6bee813eae7b24b72a1f208f))

## Changelog

All notable changes to this project are documented here. This file is managed
automatically by [release-please](https://github.com/googleapis/release-please)
from [Conventional Commit](https://www.conventionalcommits.org) messages merged
to `main`.
