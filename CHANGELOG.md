# Changelog

## Unreleased

### Changed

* Build local runner images under immutable candidate tags and require an explicit exact-image-ID promotion before changing the production `ci-runner-farm-runner:latest` tag.
* Add persistent mutation-owner leases that fence competing UI, CLI, reconcile, recycle, and daemon mutations across multi-command maintenance sessions.
* Reject V2 configured baselines that exceed post-reserve CPU or memory admission budgets, using fixed capacity for fixed pools and minimum capacity for autoscaled pools, and expose configured claims plus remaining headroom in status JSON.
* Add an idempotent Nashost fleet-audit installer and daily 06:30 audit covering exact GitHub identities and labels, runner image and Kache integrity, plugin identity, resource headroom, reconciliation state, watchdog stability, and Unraid/Gotify pass-fail notifications.
* Make the package reproducibility assertion deterministic under `pipefail` by fully extracting the inspected file before searching it.

* Move the canonical repository and scale-set helper module identity to `dinglebear-ai/ci-runner-farm`.
* Route trusted dinglebear-ai CI through the `ci-pool-ops` self-hosted pool while keeping public fork pull requests on GitHub-hosted runners.
* Include PHP CLI, ripgrep, and file inspection tools in the Nashost runner image so the repository's syntax, behavioral, and release gates run on the farm.
* Make the watchdog process-enumeration regression test independent of host PID ordering.
* Replace the temporary Kache prefetch backport with the checksum-pinned upstream v0.13.0 release across the Nashost runner image profile, layering the rollout on the current s3-v8 Kache/CC image.
* Document the final feasible 16-runner Nashost pool envelope with six Rust and one Python runner, and require pristine-image Kache version and checksum verification before fleet reconciliation.
* Continue stale-runner reconciliation after a graceful recycle is safely refused, allowing later idle stale runners to migrate without waiting behind a transiently misreported busy runner.

## [1.10.0](https://github.com/dinglebear-ai/ci-runner-farm/compare/v1.9.2...v1.10.0) (2026-08-22)


### Features

* add adaptive scale-set queue admission ([e407c17](https://github.com/dinglebear-ai/ci-runner-farm/commit/e407c17839dac0195f56542defe42a7aaba3b402))
* add bounded container runtime adapter client ([b46646e](https://github.com/dinglebear-ai/ci-runner-farm/commit/b46646ef928ed2f28cde14b966040e8d57ee7ab9))
* add distributed operator actions ([9d4256e](https://github.com/dinglebear-ai/ci-runner-farm/commit/9d4256e9d641144694cb69f51f49db39ff845ee4))
* add distributed runner farm core ([5efe6b6](https://github.com/dinglebear-ai/ci-runner-farm/commit/5efe6b6ce0325924e93b5ec1c1613339ab6004cc))
* bridge distributed placements to unraid runtime ([92cb354](https://github.com/dinglebear-ai/ci-runner-farm/commit/92cb354dae0d5d21734a11b84f00ca7dc8016729))
* compact terminal controller placement state ([f63fd02](https://github.com/dinglebear-ai/ci-runner-farm/commit/f63fd023baba2741cd817162e7cb35e69a413fe1))
* contain native runner process trees ([6b3bce1](https://github.com/dinglebear-ai/ci-runner-farm/commit/6b3bce10b3f39ab1a18a0ee1f2cd4ca3680d1d5a))
* **distributed:** project fleet status into Unraid UI ([54843b9](https://github.com/dinglebear-ai/ci-runner-farm/commit/54843b97f66f5510fec6a8090085c4e672d5e16b))
* execute controller-approved container placements ([f1684b9](https://github.com/dinglebear-ai/ci-runner-farm/commit/f1684b9d50fe4c0b85e88a975225c163e44f9cc8))
* export distributed pool policies ([2554fea](https://github.com/dinglebear-ai/ci-runner-farm/commit/2554fea5ddefef1fc5b0ff3df7f032c46cb10ed3))
* expose distributed node status in Unraid UI ([#46](https://github.com/dinglebear-ai/ci-runner-farm/issues/46)) ([264bf4d](https://github.com/dinglebear-ai/ci-runner-farm/commit/264bf4d5e7435ffc09bee055233c6a0ff2c51534))
* expose distributed operator status ([904ccee](https://github.com/dinglebear-ai/ci-runner-farm/commit/904cceed989cb3c160c3f911e92ece243cc65c26))
* hot-reload runner certificate authorization ([a114746](https://github.com/dinglebear-ai/ci-runner-farm/commit/a114746e6cd071510cbdc34adcea69730cedccd1))
* optimize distributed queue admission and JIT cleanup ([27a9ac3](https://github.com/dinglebear-ai/ci-runner-farm/commit/27a9ac3614c0215e5eb1f0d48eaf7aee09a06616))
* package distributed runner services ([5f65e77](https://github.com/dinglebear-ai/ci-runner-farm/commit/5f65e77fc809391536c831a2b1d295585d0361d2))
* package native Windows farm node ([f0c7687](https://github.com/dinglebear-ai/ci-runner-farm/commit/f0c7687a2db5869e3283190ba4d5c783d4d8dc41))
* persist portable runner runtime identity ([f00c267](https://github.com/dinglebear-ai/ci-runner-farm/commit/f00c26707152898bcffd1428fa1bdb6404c98139))
* persist runner process birth identity ([e822b7a](https://github.com/dinglebear-ai/ci-runner-farm/commit/e822b7a8091d7509a670a7dd3bda2ff163f0ad00))
* prune acknowledged node placement state ([e092e62](https://github.com/dinglebear-ai/ci-runner-farm/commit/e092e625e8d38a7553a14dbd58dc9ce01c92490b))
* resolve controller hostnames on reconnect ([158226b](https://github.com/dinglebear-ai/ci-runner-farm/commit/158226bbc824b4d8a6a0d9c3edd2212fb3e0e1a7))
* **scaleset:** rank deep acquirable job queues ([09dfc03](https://github.com/dinglebear-ai/ci-runner-farm/commit/09dfc03d09e1e68c2288fe2d1bc41331733b1862))
* select portable node execution backend ([4567106](https://github.com/dinglebear-ai/ci-runner-farm/commit/45671066cc958d1af6a2bebbca07159ab55b0091))
* share unraid runner runtime backend ([58a7244](https://github.com/dinglebear-ai/ci-runner-farm/commit/58a72447dfe9e7e883ff23d51cc2b1a47f0de652))
* **unraid:** manage cache-resident distributed node ([#45](https://github.com/dinglebear-ai/ci-runner-farm/issues/45)) ([c42b814](https://github.com/dinglebear-ai/ci-runner-farm/commit/c42b8144ed428a332e4cac0940f5a7c909cf158a))


### Bug Fixes

* **acceptance:** route jobs by scale-set label ([03a47b9](https://github.com/dinglebear-ai/ci-runner-farm/commit/03a47b9a0a2e0401743d456c69435f2f8a2afe61))
* acknowledge authoritative terminal replays ([ba8b712](https://github.com/dinglebear-ai/ci-runner-farm/commit/ba8b712757f87e7e8ba670e512b67f7510549e49))
* **adapter:** preserve container lookup failures ([f166c95](https://github.com/dinglebear-ai/ci-runner-farm/commit/f166c958995f36d3d30bfc75c8e132d31774cb97))
* **adapter:** stabilize pool policy hashes ([29e0526](https://github.com/dinglebear-ai/ci-runner-farm/commit/29e052696a8e481ac3b3b886f5bd689483318330))
* authorize interrupted migration rollback ([fa60c10](https://github.com/dinglebear-ai/ci-runner-farm/commit/fa60c1067a33d8bdd9ffb6c805ed40ea824ad1d5))
* close distributed farm review gaps ([cc79388](https://github.com/dinglebear-ai/ci-runner-farm/commit/cc793880635d672e58d43dc0de2c2b6f35b30d55))
* close JIT and session review gaps ([6a65b45](https://github.com/dinglebear-ai/ci-runner-farm/commit/6a65b451558a338e8d858f576cd1806d67615ff9))
* **controller:** fence acquired handles by pool capacity ([ef5d5e4](https://github.com/dinglebear-ai/ci-runner-farm/commit/ef5d5e485e9a0aaf3e9fd2ef9aa231fed7f2ee86))
* **controller:** honor sidecar transport timeout ([#54](https://github.com/dinglebear-ai/ci-runner-farm/issues/54)) ([ff7c2a6](https://github.com/dinglebear-ai/ci-runner-farm/commit/ff7c2a6f939f8414df9b0cbd2ca93f0fabc88651))
* **controller:** preserve fairness when offers are infeasible ([#64](https://github.com/dinglebear-ai/ci-runner-farm/issues/64)) ([1935505](https://github.com/dinglebear-ai/ci-runner-farm/commit/1935505eef4f2c6e79a230eab228f906f31b47da))
* **controller:** reclaim idle unassigned JIT runners ([#59](https://github.com/dinglebear-ai/ci-runner-farm/issues/59)) ([9ef29e9](https://github.com/dinglebear-ai/ci-runner-farm/commit/9ef29e9b4aacefa3dae53d23994facdc2704a623))
* **controller:** wait for all pool sessions before planning ([89f1769](https://github.com/dinglebear-ai/ci-runner-farm/commit/89f17696ebe1e91249ddecf2520d48e34685b5f2))
* **controller:** wait for all pool sessions before planning ([9866637](https://github.com/dinglebear-ai/ci-runner-farm/commit/98666373fdc1af923d004690b5fc750118b9f7c1))
* **deploy:** preserve distributed adapter executable ([710fb0c](https://github.com/dinglebear-ai/ci-runner-farm/commit/710fb0c01c20baa992f0437cc2684018ea916aa1))
* **deploy:** preserve distributed adapter executable ([f795356](https://github.com/dinglebear-ai/ci-runner-farm/commit/f795356a5b2527e58cee81211b723534b794eb86))
* **distributed:** materialize runner links and route scale-set jobs ([6a4fe18](https://github.com/dinglebear-ai/ci-runner-farm/commit/6a4fe18de0a9605393e93964c34176725f82340c))
* emit complete live probe runtime config ([#48](https://github.com/dinglebear-ai/ci-runner-farm/issues/48)) ([fff34c3](https://github.com/dinglebear-ai/ci-runner-farm/commit/fff34c3a1f91a65496e60066022205eed5f1f7df))
* fence JIT retirement from network polls ([06cb4fb](https://github.com/dinglebear-ai/ci-runner-farm/commit/06cb4fbc84942a53509bccd2ff5f2da064ee3e9e))
* harden adaptive admission and JIT cleanup ([e7d47ab](https://github.com/dinglebear-ai/ci-runner-farm/commit/e7d47abf3d40bd7ac6a9a6893172a87d01dc7a34))
* harden controller operator diagnostics ([5e78428](https://github.com/dinglebear-ai/ci-runner-farm/commit/5e7842806ae95d89d385b460a0a8d4471aaff5ca))
* harden cross-platform controller recovery ([0e95021](https://github.com/dinglebear-ai/ci-runner-farm/commit/0e950214be70aac916dcce07e7115794dfdf65be))
* harden distributed CI portability ([b297b04](https://github.com/dinglebear-ai/ci-runner-farm/commit/b297b04d53f477655e59bfdab1f8e59105abc8a6))
* harden Windows node service install ([66b690e](https://github.com/dinglebear-ai/ci-runner-farm/commit/66b690ea5a08dca2d096a99b0624ed728f1c4e08))
* interrupt long polls for JIT retirement ([f602b7a](https://github.com/dinglebear-ai/ci-runner-farm/commit/f602b7ad56ed97de2cf3cae1d18bd9640bbe3b18))
* isolate classic migration inventory ([b03c380](https://github.com/dinglebear-ai/ci-runner-farm/commit/b03c38046f59066933c7c67d3b280bfc276e417e))
* keep distributed runners outside classic stop ([f5b1f6a](https://github.com/dinglebear-ai/ci-runner-farm/commit/f5b1f6a9eac1834c0b5c1cef3071ca89b30ba4bf))
* **node:** accept safe runner archive symlinks ([#42](https://github.com/dinglebear-ai/ci-runner-farm/issues/42)) ([6036649](https://github.com/dinglebear-ai/ci-runner-farm/commit/60366495f3db4a8c207e84f4d3f73acc3fdd99e1))
* **node:** materialize read-only runner directories ([2f6eeda](https://github.com/dinglebear-ai/ci-runner-farm/commit/2f6eedaff86c77660760a41138a83f68c99f3b4b))
* **node:** materialize read-only runner directories ([4e43149](https://github.com/dinglebear-ai/ci-runner-farm/commit/4e43149422d61eacae75ae528c984ec5743dd3a8))
* **node:** preserve safe runner template symlinks ([34345b3](https://github.com/dinglebear-ai/ci-runner-farm/commit/34345b3c6745b2c5ec0f5a3b268c55f81e9a071a))
* preflight host-local runner image bases ([21aca32](https://github.com/dinglebear-ai/ci-runner-farm/commit/21aca32ce6c208f55426179fe917e644cdc22a58))
* preserve cleanup ownership across retries ([57fb5fe](https://github.com/dinglebear-ai/ci-runner-farm/commit/57fb5fe44a9c4d21fa682dba66e88b371c78416f))
* preserve distributed outage and bundle identity ([1896ca1](https://github.com/dinglebear-ai/ci-runner-farm/commit/1896ca1b2c58f9b3ef125dc194ff03b8954387c5))
* re-register nodes after controller state loss ([e620308](https://github.com/dinglebear-ai/ci-runner-farm/commit/e620308a2c3ca3d3b31016fd52a9a26a87b4d175))
* readopt observed placements after node restart ([86aee55](https://github.com/dinglebear-ai/ci-runner-farm/commit/86aee55ce02eccf69bef7f53fbc2a57913f14b02))
* remove retired JIT runner data ([015e450](https://github.com/dinglebear-ai/ci-runner-farm/commit/015e450301cb14ecc41d5736f3a4b95c739876d4))
* render production demand snapshots ([dc84541](https://github.com/dinglebear-ai/ci-runner-farm/commit/dc845418b8e978ca939787c58c96f51ba0c1c1bb))
* roll back failed Windows service upgrades ([0e7fcd9](https://github.com/dinglebear-ai/ci-runner-farm/commit/0e7fcd93735531cccb21be890a5764f0bcbf6ef7))
* rotate admission past unplaceable pools ([6216e1d](https://github.com/dinglebear-ai/ci-runner-farm/commit/6216e1d609b615bbc5361d019f0f0af62694865c))
* run distributed JIT jobs as configured user ([#70](https://github.com/dinglebear-ai/ci-runner-farm/issues/70)) ([03dc2ea](https://github.com/dinglebear-ai/ci-runner-farm/commit/03dc2ea5a4a27da2fa003223ef5d26e5f64b5cbc))
* **scaleset:** align demand TTL with controller ([#52](https://github.com/dinglebear-ai/ci-runner-farm/issues/52)) ([eefe0fd](https://github.com/dinglebear-ai/ci-runner-farm/commit/eefe0fdfbb0bb918b5aca7bdc87e3c9084dd52ef))
* **scaleset:** harden adaptive queue admission ([d31d49d](https://github.com/dinglebear-ai/ci-runner-farm/commit/d31d49d73b019c8d2b81616578f2b4b68257d7a4))
* **scaleset:** preserve demand across long polls ([#53](https://github.com/dinglebear-ai/ci-runner-farm/issues/53)) ([0a7e68e](https://github.com/dinglebear-ai/ci-runner-farm/commit/0a7e68e0441636239f1798ecb5e005cfdff722d8))
* **scaleset:** publish valid initial pool snapshots ([0ca4479](https://github.com/dinglebear-ai/ci-runner-farm/commit/0ca447992ada49f4ef94e221d1be94a42d5e99ea))
* **scaleset:** publish valid initial pool snapshots ([64d3840](https://github.com/dinglebear-ai/ci-runner-farm/commit/64d38401287541c191d5651e14df48f21df87dc0))
* **scaleset:** serialize empty poll handles as arrays ([#51](https://github.com/dinglebear-ai/ci-runner-farm/issues/51)) ([82d65ba](https://github.com/dinglebear-ai/ci-runner-farm/commit/82d65bae75f135ccf9a9c4aca4b96ae0bd2fbcd1))
* **scaleset:** stabilize reassigned job handles ([#55](https://github.com/dinglebear-ai/ci-runner-farm/issues/55)) ([82386cb](https://github.com/dinglebear-ai/ci-runner-farm/commit/82386cbee0999fd564e65ad7f748d573b947bd04))
* serialize empty scale-set handles as arrays ([#50](https://github.com/dinglebear-ai/ci-runner-farm/issues/50)) ([81f2531](https://github.com/dinglebear-ai/ci-runner-farm/commit/81f253185234a36e83e15f50259f99b048356086))
* **windows:** pass sc failure options portably ([#44](https://github.com/dinglebear-ai/ci-runner-farm/issues/44)) ([d76c43f](https://github.com/dinglebear-ai/ci-runner-farm/commit/d76c43f45710f68e3dc8ec0d9d240a981d362c45))

## [1.9.2](https://github.com/dinglebear-ai/ci-runner-farm/compare/v1.9.1...v1.9.2) (2026-08-10)


### Bug Fixes

* address merged PR review findings ([3265656](https://github.com/dinglebear-ai/ci-runner-farm/commit/3265656d081517add74faeedc23559dba25e15ba))
* close PR review lifecycle and release gaps ([51da252](https://github.com/dinglebear-ai/ci-runner-farm/commit/51da2523644dee00c97bd3081d6e7f8e9c9dccba))
* close release and lifecycle review gaps ([4c97138](https://github.com/dinglebear-ai/ci-runner-farm/commit/4c9713853bee6058a590a1bd60ca41bdb2e19714))
* complete candidate and audit review hardening ([acba7e4](https://github.com/dinglebear-ai/ci-runner-farm/commit/acba7e4d96cf18f89001f1f487529a30160c7847))
* complete reconciliation and audit remediation ([57b2b55](https://github.com/dinglebear-ai/ci-runner-farm/commit/57b2b55a87aa265eb21699e5f5fc57be2a0d4ae9))
* harden reconciliation activation and audit parsing ([df7fdd8](https://github.com/dinglebear-ai/ci-runner-farm/commit/df7fdd87927c055ded26cf43902344ff22a33bcd))
* recover runner fleet after transient boot failures ([#36](https://github.com/dinglebear-ai/ci-runner-farm/issues/36)) ([010a911](https://github.com/dinglebear-ai/ci-runner-farm/commit/010a9113508b671e071af11b130a89a3396876ef))
* remove runtime validation artifacts ([5faa3f5](https://github.com/dinglebear-ai/ci-runner-farm/commit/5faa3f5033f38667619fd48688ee247949067c87))
* remove runtime validation artifacts ([06f33ef](https://github.com/dinglebear-ai/ci-runner-farm/commit/06f33efc5e26fd2123e5ed533174b3036502b8b6))
* run persistent fleet audit through bash ([a803fa9](https://github.com/dinglebear-ai/ci-runner-farm/commit/a803fa956b8188cfdca6e9ef7ad36f6c63982b72))
* run persistent fleet audit through bash ([8cc3f17](https://github.com/dinglebear-ai/ci-runner-farm/commit/8cc3f172433bec8a52e8b8d9fdae1c822e1797e5))
* scope watchdog audit to host namespace ([a3afff8](https://github.com/dinglebear-ai/ci-runner-farm/commit/a3afff8dedf256ea33d99942dea4aeaab7c7b607))
* scope watchdog audit to host namespace ([a082d74](https://github.com/dinglebear-ai/ci-runner-farm/commit/a082d74eb2b0f118c5c4a5daf1583f6cd4e63b33))
* serialize lease fencing and unify endpoint validation ([1be9d3d](https://github.com/dinglebear-ai/ci-runner-farm/commit/1be9d3d1fcb6642851772e9676f755811693d356))
* validate runtime with a configured pool ([c300f2c](https://github.com/dinglebear-ai/ci-runner-farm/commit/c300f2c06fb1bdcaa4422ccce98f75dd459ef690))
* validate runtime with a configured pool ([f450e68](https://github.com/dinglebear-ai/ci-runner-farm/commit/f450e684d1981172f7cfc6755f60bd8086f1ea93))

## [1.9.1](https://github.com/dinglebear-ai/ci-runner-farm/compare/v1.9.0...v1.9.1) (2026-08-08)


### Bug Fixes

* **runner:** fail closed when the configured image is unavailable, recover a missing built-in image alias from verified promotion metadata, and keep safe reconciliation retries alive ([#29](https://github.com/dinglebear-ai/ci-runner-farm/pull/29))
* **ui:** isolate controls from Unraid button styles ([#27](https://github.com/dinglebear-ai/ci-runner-farm/issues/27)) ([ba73210](https://github.com/dinglebear-ai/ci-runner-farm/commit/ba732106fa6850a628552871844a8bc3651c3c85))

### Changed

* Scrub internal deployment hostnames and concrete network addresses from public documentation, deployment profiles, and test fixtures ([#17](https://github.com/dinglebear-ai/ci-runner-farm/pull/17)).

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
