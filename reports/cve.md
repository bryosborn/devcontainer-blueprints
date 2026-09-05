# Toolbox image CVE report

Generated: `2026-09-05T16:50:05Z`

All three images passed the raw **zero Critical / zero High** gate. Findings include unfixed advisories and all severities.

| Profile | Image | Immutable image ID | Docker size | Content size | Unknown | Low | Medium | High | Critical |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| dev | `local/toolbox-dev:0.2.0` | `sha256:f0c75888d68b1df15704cfffe8692462274b2e9d202bb290a7671b1cf1798243` | 9.17GB | 2.5 GiB | 0 | 1 | 1 | 0 | 0 |
| build | `local/toolbox-build:0.2.0` | `sha256:5eab5d01a2a3237bcb9c7add64d7fc363c866575c11957beb091316f8275be2a` | 6.71GB | 1.6 GiB | 0 | 1 | 1 | 0 | 0 |
| kaniko | `local/toolbox-kaniko:0.2.0` | `sha256:d6bf2197bf78e8dfba075f945749fb62c46146f8f360ca1a7f99bca0c942c017` | 6.57GB | 1.5 GiB | 3 | 1 | 1 | 0 | 0 |

`Docker size` is the rounded value reported by `docker image ls` on the build host. `Content size` is the exact `docker image inspect .Size` value rendered in IEC units; container backends account for expanded snapshots and stored content differently.

## Supply and scanner identity

- `config/images.env` SHA256: `cffa434566694786054762da250c804a09099b4699c7e6910d47f3e355406f7b`
- Trivy: `0.74.0`
- Vulnerability DB: version `2`, updated `2026-09-05T13:02:41.107875606Z`
- Java DB: version `1`, updated `2026-09-05T01:05:40.708480615Z`
- Exact database-byte manifest SHA256: `632574f29d7d85f92d768230d00534ff6bdbf22bd0c988fb9ef460f1c502ee6b` (4 files)

| Profile | YAML SHA256 | Lock SHA256 | SBOM SHA256 |
| --- | --- | --- | --- |
| dev | `91b92ded9e837b00bb84b48ebf8fbac6159c3b9f2bb48cf12ea059c56542fe89` | `7b0abad0ab02c255ac13021aa923cf38b2dde1f0b2889bdeab37394562fda6ed` | `5e8cfe5260fee664ee4a261dbfc1f54c3977e86d3d24168d11879fc7e9bc9e4f` |
| build | `1db71e9d53ab070a5242bacafdc9506704f8a19fe8c8f93aa0392ad123987739` | `b4cec46fcce99c905e1f1dd65cd6a30bb8216ed0caaeb3d87bbb7ceff7db7575` | `c2f17e633fbba23d8498570fee696fa2248bde51b9e4581af2651da377ef514b` |
| kaniko | `c7f610286934e486059cb72892f6b0b3ebf7c7d95802840df08b483316ca39b0` | `31d4cb6a047292435719a283e0c79f69094a8c15273bb838eac639fc61fe71cf` | `2f8228ca95a90b787ba1a6efcdd91313153c637a288cd311ddba0fcfc979408e` |

## Advisory details

| Advisory | Severity | Package | Installed | Fixed | Status | Target | Occurrences | Title |
| --- | --- | --- | --- | --- | --- | --- | ---: | --- |
| [CVE-2026-56855](https://avd.aquasec.com/nvd/cve-2026-56855) | UNKNOWN | `golang.org/x/crypto` | `v0.55.0` | `0.56.0` | fixed | `kaniko/executor` | 1 | Previously, after a channel has been established, a malicious peer cou ... |
| [CVE-2026-78662](https://avd.aquasec.com/nvd/cve-2026-78662) | UNKNOWN | `golang.org/x/crypto` | `v0.55.0` | `0.56.0` | fixed | `kaniko/executor` | 1 | Previously, a channel registered in the mux's chanList is not usable u ... |
| GO-2026-5932 | UNKNOWN | `golang.org/x/crypto` | `v0.55.0` | `—` | affected | `kaniko/executor` | 1 | The golang.org/x/crypto/openpgp package is unmaintained, unsafe by design, and has known security issues |
| [GHSA-cq8v-f236-94qc](https://github.com/advisories/GHSA-cq8v-f236-94qc) | LOW | `rand` | `0.9.2` | `0.9.3, 0.10.1, 0.8.6` | fixed | `usr/local/rustup/toolchains/nightly-2026-09-04-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/portable-simd/Cargo.lock` | 3 | Rand is unsound with a custom logger using rand::rng() |
| [GHSA-7gcf-g7xr-8hxj](https://github.com/advisories/GHSA-7gcf-g7xr-8hxj) | MEDIUM | `serde_with` | `3.18.0` | `3.21.0` | fixed | `usr/local/rustup/toolchains/nightly-2026-09-04-x86_64-unknown-linux-gnu/lib/rustlib/src/rust/library/stdarch/Cargo.lock` | 3 | serde_with: KeyValueMap serialization panics on empty sequence or map entries |

## Scope notes

The dev image's uninstalled VSIX transfer archive is excluded from its primary gate and SBOM. The archive is inert until a user installs it and remains hash-locked in the profile supply.

Trivy does not establish advisory coverage for the downloaded Playwright Chromium executables. A zero raw finding count does not prove that those browser binaries have complete advisory coverage.
