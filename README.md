# u-boot-rockchip

[![Build & Release](https://github.com/schneid-l/u-boot-rockchip/actions/workflows/build.yaml/badge.svg?branch=main)](https://github.com/schneid-l/u-boot-rockchip/actions/workflows/build.yaml)
[![Latest release](https://img.shields.io/github/v/release/schneid-l/u-boot-rockchip?label=release&color=blue)](https://github.com/schneid-l/u-boot-rockchip/releases/latest)

Pre-built, signed [U-Boot](https://www.denx.de/project/u-boot/) binaries for
**120 mainline-supported Rockchip ARM64 boards**, built reproducibly from
upstream sources and published as signed GitHub releases.

Every binary carries [SLSA build provenance](https://slsa.dev/); each release
ships a [cosign](https://docs.sigstore.dev/)-signed `SHA256SUMS` and an SBOM, and
records the exact U-Boot, Arm Trusted Firmware, rkbin and OP-TEE versions used.

- **Find your board:** [docs/boards.md](docs/boards.md)
- **Download:** [latest release](https://github.com/schneid-l/u-boot-rockchip/releases/latest)

## Quick start

1. Look up your board in [docs/boards.md](docs/boards.md) to get its U-Boot
   **defconfig** (e.g. `orangepi-5-rk3588s`) — the filenames use that name.

2. Download the image (Orange Pi 5 shown):

   ```bash
   wget https://github.com/schneid-l/u-boot-rockchip/releases/latest/download/u-boot-orangepi-5-rk3588s.bin
   ```

3. Flash it from Linux on the board (or with the storage attached). Replace the
   device with yours (`lsblk` / `cat /proc/mtd`), then reboot:

   ```bash
   # SD card / eMMC — written at sector 64
   sudo dd if=u-boot-orangepi-5-rk3588s.bin of=/dev/mmcblkX seek=64 conv=notrunc,fsync

   # SPI flash (boards with a -spi image) — flashcp erases as it writes
   sudo flashcp -v u-boot-orangepi-5-rk3588s-spi.bin /dev/mtd0
   ```

> [!WARNING]
> Flashing the wrong file or device can make a board unbootable. Confirm your
> board's exact defconfig in [docs/boards.md](docs/boards.md) first.

## What gets published

For every board, named after its defconfig `<board>`:

| File | Boot medium | Notes |
| ---- | ----------- | ----- |
| `u-boot-<board>.bin` | SD card / eMMC | Always published (`dd … seek=64`). |
| `u-boot-<board>-spi.bin` | SPI flash | Boards that support SPI boot. |
| `u-boot-<board>-optee.bin`, `…-optee-spi.bin` | as above | Bundles the OP-TEE secure world (BL32) — rk3588 / rk3399 / px30 / rk3326 only. **Experimental.** |
| `u-boot-<soc>.manifest.json` | — | Exact component versions per SoC group. |
| `SHA256SUMS` + `SHA256SUMS.cosign.bundle` | — | Checksums and their cosign signature. |
| `sbom.cdx.json` | — | CycloneDX SBOM of the upstream components. |

## Verify a binary

```bash
# SLSA provenance, per binary
gh attestation verify u-boot-orangepi-5-rk3588s.bin --repo schneid-l/u-boot-rockchip \
  --signer-workflow schneid-l/u-boot-rockchip/.github/workflows/build.yaml

# Signed checksums — download SHA256SUMS and SHA256SUMS.cosign.bundle
cosign verify-blob \
  --bundle SHA256SUMS.cosign.bundle \
  --certificate-identity 'https://github.com/schneid-l/u-boot-rockchip/.github/workflows/build.yaml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
```

## Build it yourself

Builds run in a multi-stage Docker container — you need `buildx` and an `arm64`
builder (native on Apple Silicon). Pass `SOURCE_DATE_EPOCH` for bit-for-bit
reproducible output.

```bash
# Orange Pi 5 (rk3588): TF-A BL31 from source + rkbin DDR blob
docker build --target export --output type=local,dest=./out \
  --build-arg SOC=rk3588 \
  --build-arg DEFCONFIGS="orangepi-5-rk3588s" \
  --build-arg DDR_SUBDIR=rk35 \
  --build-arg DDR_GLOB="rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v[0-9.]*.bin" \
  --build-arg ATF_PLAT=rk3588 \
  .
```

[`boards.json`](boards.json) holds the per-SoC parameters and drives the CI
matrix. Pass a SoC's space-separated `DEFCONFIGS` to build all its boards at once,
reusing the shared blobs. Build args:

| Arg | Purpose |
| --- | ------- |
| `SOC` | SoC group id (used in the manifest filename). |
| `DEFCONFIGS` | Space-separated U-Boot defconfigs (no `_defconfig` suffix). |
| `DDR_KIND` | `uboot` (DRAM init from source — blob-free) or `rkbin` (Rockchip DDR blob). |
| `DDR_SUBDIR` / `DDR_GLOB` | rkbin directory + glob for the DDR blob (`DDR_KIND=rkbin`). |
| `BL31_KIND` | `tfa` (build Arm Trusted Firmware) or `rkbin` (prebuilt BL31). |
| `ATF_PLAT` / `ATF_TRACK` | TF-A `PLAT`; `modern` (v2.15.0) or `legacy` (v2.12.0). |
| `BL31_GLOB` | rkbin BL31 `.elf` glob (`BL31_KIND=rkbin`). |
| `OPTEE` / `OPTEE_PLATFORM` | `on` to bundle OP-TEE for `rockchip-<platform>`. |
| `CONFIG_FRAGMENTS` | Space-separated Kconfig fragments to merge (see below). |
| `VARIANT_SUFFIX` | Suffix for the output filenames, e.g. `-httpboot`. |

### Custom Kconfig fragments

The published binaries are stock upstream defconfigs. To build a board with
extra config — netboot, a different console, a custom `bootcmd` — put the
settings in a `.config` fragment and pass its directory as the `fragments`
build context:

```bash
docker build --target export --output type=local,dest=./out \
  --build-context fragments=./my-fragments \
  --build-arg CONFIG_FRAGMENTS="http-boot.config" \
  --build-arg VARIANT_SUFFIX="-httpboot" \
  --build-arg SOC=rk3588 \
  --build-arg DEFCONFIGS="orangepi-5-rk3588s" \
  --build-arg DDR_SUBDIR=rk35 \
  --build-arg DDR_GLOB="rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v[0-9.]*.bin" \
  --build-arg ATF_PLAT=rk3588 \
  .
```

Fragments are merged with U-Boot's own `merge_config.sh` after `make
<board>_defconfig`, then reconciled with `olddefconfig`. Every symbol a
fragment sets must survive that reconciliation or the build fails: Kconfig
drops assignments with unmet dependencies silently, which would otherwise
yield firmware missing exactly the feature you asked for. `VARIANT_SUFFIX`
keeps the output filenames distinct from stock, and the manifest records each
fragment's name and SHA-256.

## Supported boards

**120 boards across 10 SoC families** — full list with filenames in
[docs/boards.md](docs/boards.md).

| SoC family | BL31 | DDR init | OP-TEE variant |
| ---------- | ---- | -------- | -------------- |
| rk3588 / rk3588s | TF-A v2.15.0 | rkbin blob | yes |
| rk3576 | TF-A v2.15.0 | rkbin blob | no |
| rk3568 | TF-A v2.15.0 | rkbin blob | no |
| rk3566 | TF-A v2.15.0 (rk3568 PLAT) | rkbin blob | no |
| rk3528 | rkbin BL31 | rkbin blob | no |
| rk3399 / rk3399pro | TF-A v2.12.0 | rkbin blob | yes |
| rk3328 | TF-A v2.12.0 | rkbin blob | no |
| rk3308 | rkbin BL31 | rkbin blob | no |
| rk3326 | TF-A v2.15.0 (px30 PLAT) | U-Boot source | yes |
| px30 | TF-A v2.15.0 | U-Boot source | yes |

**47 boards build fully blob-free** — DRAM init from U-Boot's own TPL and BL31
from mainline TF-A: the rk3399, rk3328, rk3326 and px30 boards, minus the two
`generic-*` defconfigs that force an external TPL. On rk3399/rk3328 the rkbin DDR
blob is fetched only for those `generic-*` boards; every other board ignores it
(verified byte-identical). The `FOSS` column in [docs/boards.md](docs/boards.md)
marks each one.

**rk3328 and rk3399 pin TF-A v2.12.0**: later releases overflow their 4 KB
`PMUSRAM` region (an upstream bug, still on `master`), so Renovate holds that pin.

**Not included:** rk3368 (predates the single-image binman flow) and 32-bit
Rockchip SoCs (different toolchain and boot flow).

## Automated builds

[Renovate](https://docs.renovatebot.com/) tracks the pinned versions — U-Boot,
TF-A, OP-TEE, the rkbin commit, the base image and every GitHub Action — and
opens a PR when one moves. CI builds every board (one matrix job per SoC group,
on `ghcr.io`-cached layers); when it's green Renovate auto-merges, and a merge to
`main` publishes a signed release tagged with the U-Boot version.

A release is cut **only when a firmware component changes** (U-Boot, TF-A, OP-TEE
or rkbin). Base-image and GitHub-Action bumps are merged and validated but don't
produce a release.

The build runs only for trusted PRs — Renovate, the repo owner, or a PR the owner
labels `build`; lint and board-list validation run on every PR.

## Upstream projects and licenses

This repository is build infrastructure only. The binaries it produces come from:

| Project | Role | License |
| ------- | ---- | ------- |
| [U-Boot](https://github.com/u-boot/u-boot) | Bootloader (TPL/SPL + proper) | GPL-2.0-or-later |
| [Arm Trusted Firmware](https://github.com/ARM-software/arm-trusted-firmware) | Secure monitor (BL31) | BSD-3-Clause |
| [OP-TEE OS](https://github.com/OP-TEE/optee_os) | Secure world (BL32, `-optee` only) | BSD-2-Clause |
| [rkbin](https://github.com/rockchip-linux/rkbin) | Rockchip DDR init + prebuilt BL31 blobs | [Rockchip license](https://github.com/rockchip-linux/rkbin/blob/master/LICENSE) — redistribution permitted |

The rkbin blobs are redistributed as-is (not built from source, not modified).
This repository's own configuration and scripts are **GPL-2.0** — see [LICENSE](LICENSE).

## Issues

Found a board that doesn't boot, or want one added?
[Open an issue](https://github.com/schneid-l/u-boot-rockchip/issues) with the
board, the exact filename you flashed, and the boot medium.
