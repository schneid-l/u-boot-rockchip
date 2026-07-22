# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89

# ---------------------------------------------------------------------------
# Versions (single source of truth — declared as global ARGs, inherited by
# every stage). Renovate keeps these up to date; see .github/renovate.json5.
# ---------------------------------------------------------------------------

# renovate: datasource=github-tags depName=u-boot packageName=u-boot/u-boot versioning=loose
ARG U_BOOT_VERSION=v2026.04
# renovate: datasource=github-tags depName=arm-trusted-firmware packageName=ARM-software/arm-trusted-firmware versioning=loose
ARG ATF_VERSION=v2.15.0
# Older TF-A for rk3328/rk3368/rk3399: TF-A releases after v2.12 overflow these
# SoCs' fixed 4 KB PMUSRAM region by 8 bytes (an upstream regression, still
# present on TF-A master). Pinned; Renovate is told to leave it alone — see
# .github/renovate.json5. Bump manually once upstream fixes the overflow.
# renovate: datasource=github-tags depName=arm-trusted-firmware-legacy packageName=ARM-software/arm-trusted-firmware versioning=loose
ARG ATF_LEGACY_VERSION=v2.12.0
# renovate: datasource=github-tags depName=optee_os packageName=OP-TEE/optee_os versioning=semver
ARG OPTEE_VERSION=4.10.0
# rkbin has no tags/releases, so it is pinned to an exact commit of `master`.
# renovate: datasource=git-refs depName=rkbin packageName=https://github.com/rockchip-linux/rkbin currentValue=master
ARG RKBIN_REF=ecb4fcbe954edf38b3ae037d5de6d9f5bccf81f4

# ---------------------------------------------------------------------------
# Per-build selectors (one SoC group per build; defaults reproduce a single
# Orange Pi 5 binary so a bare `docker build .` works out of the box). CI
# drives these from boards.json — see .github/workflows/build.yaml.
# ---------------------------------------------------------------------------
# SoC group identifier (used in the per-group manifest filename).
ARG SOC=rk3588
# Space-separated list of U-Boot defconfigs (without the _defconfig suffix).
ARG DEFCONFIGS="orangepi-5-rk3588s"
# DDR (TPL) init. "rkbin": use Rockchip's prebuilt DDR blob (required by SoCs
# that imply ROCKCHIP_EXTERNAL_TPL). "uboot": U-Boot initialises DRAM from its
# own TPL — a fully open-source boot chain, for SoCs with a mainline DDR driver.
ARG DDR_KIND=rkbin
# rkbin DDR blob: directory under rkbin bin/ and a glob selecting the canonical
# blob; the highest version is picked.
ARG DDR_SUBDIR=rk35
ARG DDR_GLOB="rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v[0-9.]*.bin"
# BL31 source: "tfa" builds Arm Trusted Firmware for ATF_PLAT; "rkbin" copies a
# prebuilt BL31 .elf matching BL31_GLOB from rkbin (SoCs without mainline TF-A).
ARG BL31_KIND=tfa
ARG ATF_PLAT=rk3588
# Which TF-A to build: "modern" (ATF_VERSION) or "legacy" (ATF_LEGACY_VERSION).
ARG ATF_TRACK=modern
ARG BL31_GLOB=""
# OP-TEE secure world (BL32): "off" (default) or "on" for the -optee variant.
ARG OPTEE=off
ARG OPTEE_PLATFORM=rk3588
# Kconfig fragments merged into every defconfig of the group — space-separated
# filenames resolved inside the `fragments` build context (see below). Empty
# for the published builds, which are stock upstream defconfigs.
ARG CONFIG_FRAGMENTS=""
# Suffix for the output filenames, so a customised build can never be mistaken
# for a stock one (e.g. "-httpboot" → u-boot-orangepi-5-rk3588s-httpboot.bin).
ARG VARIANT_SUFFIX=""

# ---------------------------------------------------------------------------
# Base build environment. The base image is pinned by digest and kept current
# by Renovate (docker:pinDigests).
# ---------------------------------------------------------------------------
FROM ubuntu:26.04@sha256:f3d28607ddd78734bb7f71f117f3c6706c666b8b76cbff7c9ff6e5718d46ff64 AS base

ARG DEBIAN_FRONTEND=noninteractive

# pipefail so a failed download in a `curl | tar` pipe fails the build. Inherited
# by every child stage.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache && \
    apt-get update && apt-get install --no-install-recommends -y \
      bc \
      bison \
      build-essential \
      ca-certificates \
      ccache \
      curl \
      device-tree-compiler \
      flex \
      git \
      libgnutls28-dev \
      libssl-dev \
      lz4 \
      pkg-config \
      python3 \
      python3-dev \
      python3-pycryptodome \
      python3-pyelftools \
      python3-setuptools \
      swig \
      uuid-dev \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Rockchip blobs (rkbin), pinned to an exact commit. Only the one bin/ subdir
# this SoC needs is fetched (a partial, sparse checkout ~15 MB), not the whole
# multi-gigabyte repository.
# ---------------------------------------------------------------------------
FROM base AS rkbin
ARG RKBIN_REF
ARG DDR_SUBDIR
WORKDIR /rkbin
RUN git init -q && \
    git remote add origin https://github.com/rockchip-linux/rkbin.git && \
    git -c protocol.version=2 fetch -q --depth 1 --filter=blob:none origin "${RKBIN_REF}" && \
    git sparse-checkout init --cone && \
    git sparse-checkout set "bin/${DDR_SUBDIR}" && \
    git checkout -q FETCH_HEAD

# DDR (TPL): rkbin prebuilt blob, picked by glob (highest version wins)...
FROM rkbin AS ddr-rkbin
ARG DDR_SUBDIR
ARG DDR_GLOB
RUN mkdir -p /ddr && \
    blob="$(ls -1 /rkbin/bin/${DDR_SUBDIR}/${DDR_GLOB} | sort -V | tail -n1)" && \
    test -n "${blob}" && \
    cp "${blob}" /ddr/tpl.bin && \
    printf 'rkbin' > /ddr/ddr.source && \
    basename "${blob}" | sed -E 's/.*_v([0-9.]+)\.bin/v\1/' > /ddr/ddr.version

# ...or no blob at all: U-Boot's own TPL initialises DRAM from source. The
# absence of /ddr/tpl.bin tells the build to leave ROCKCHIP_TPL unset.
FROM base AS ddr-uboot
RUN mkdir -p /ddr && \
    printf 'u-boot' > /ddr/ddr.source && \
    printf 'built from U-Boot source' > /ddr/ddr.version

FROM ddr-${DDR_KIND} AS ddr

# ---------------------------------------------------------------------------
# BL31: built from mainline Arm Trusted Firmware for ATF_PLAT...
# ---------------------------------------------------------------------------
FROM base AS bl31-tfa
ARG ATF_VERSION
ARG ATF_LEGACY_VERSION
ARG ATF_TRACK
ARG ATF_PLAT
ARG SOURCE_DATE_EPOCH
# arm-none-eabi builds the rk3399 PMU Cortex-M0 firmware; unused by other PLATs.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y gcc-arm-none-eabi
RUN ver="$([ "${ATF_TRACK}" = legacy ] && echo "${ATF_LEGACY_VERSION}" || echo "${ATF_VERSION}")" && \
    mkdir -p /atf/src /bl31 && \
    printf '%s' "${ver}" > /bl31/bl31.version && \
    printf 'arm-trusted-firmware' > /bl31/bl31.source && \
    curl -fsSL "https://github.com/ARM-software/arm-trusted-firmware/archive/refs/tags/${ver}.tar.gz" \
      | tar -xz -C /atf/src --strip-components=1
WORKDIR /atf/src
# TF-A defaults BUILD_MESSAGE_TIMESTAMP to __TIME__/__DATE__ (the wall-clock
# build time) and injects it raw into a C string, which breaks reproducibility.
# Pin it to a SOURCE_DATE_EPOCH-derived value, quoted so it stays a string literal.
RUN ts="$([ -n "${SOURCE_DATE_EPOCH}" ] && date -u -d "@${SOURCE_DATE_EPOCH}" '+%H:%M:%S, %b %d %Y' || echo 'reproducible build')" && \
    CFLAGS=--param=min-pagesize=0 make -j"$(nproc)" DEBUG=0 PLAT="${ATF_PLAT}" \
      BUILD_MESSAGE_TIMESTAMP="\"${ts}\"" bl31 && \
    cp "build/${ATF_PLAT}/release/bl31/bl31.elf" /bl31/bl31.elf

# ...or a prebuilt BL31 .elf from rkbin for SoCs without mainline TF-A support.
FROM rkbin AS bl31-rkbin
ARG DDR_SUBDIR
ARG BL31_GLOB
RUN mkdir -p /bl31 && \
    elf="$(ls -1 /rkbin/bin/${DDR_SUBDIR}/${BL31_GLOB} | sort -V | tail -n1)" && \
    test -n "${elf}" && \
    cp "${elf}" /bl31/bl31.elf && \
    basename "${elf}" | sed -E 's/.*_v([0-9.]+)\.elf/v\1/' > /bl31/bl31.version && \
    printf 'rkbin' > /bl31/bl31.source

FROM bl31-${BL31_KIND} AS bl31

# ---------------------------------------------------------------------------
# OP-TEE secure world (BL32), built from source only for the -optee variant.
# `tee-off` is an empty placeholder so the default build skips OP-TEE entirely.
# ---------------------------------------------------------------------------
FROM base AS tee-off
RUN mkdir -p /optee && printf 'none' > /optee/optee.version

FROM base AS tee-on
ARG OPTEE_VERSION
ARG OPTEE_PLATFORM
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install --no-install-recommends -y python3-cryptography
RUN mkdir -p /optee/src && \
    curl -fsSL "https://github.com/OP-TEE/optee_os/archive/refs/tags/${OPTEE_VERSION}.tar.gz" \
      | tar -xz -C /optee/src --strip-components=1
WORKDIR /optee/src
RUN make -j"$(nproc)" PLATFORM="rockchip-${OPTEE_PLATFORM}" CFG_ARM64_core=y CFG_USER_TA_TARGETS=ta_arm64 CROSS_COMPILE64= O=out && \
    cp out/core/tee.elf /optee/tee.elf && \
    printf '%s' "${OPTEE_VERSION}" > /optee/optee.version

FROM tee-${OPTEE} AS tee

# ---------------------------------------------------------------------------
# Kconfig fragments. Empty by default, so the published builds are stock
# upstream defconfigs. Downstream users override this stage with a named build
# context to merge extra config into every board of the group:
#
#   docker build --build-context fragments=./my-fragments \
#     --build-arg CONFIG_FRAGMENTS="http-boot.config" \
#     --build-arg VARIANT_SUFFIX="-httpboot" ...
#
# Every symbol a fragment sets is asserted to survive `olddefconfig`, so an
# unmet dependency fails the build instead of silently dropping the feature.
# ---------------------------------------------------------------------------
FROM scratch AS fragments

# ---------------------------------------------------------------------------
# U-Boot source (depends only on U_BOOT_VERSION, so it is shared across every
# board of a SoC group).
# ---------------------------------------------------------------------------
FROM base AS u-boot-source
ARG U_BOOT_VERSION
RUN mkdir -p /u-boot/src && \
    curl -fsSL "https://github.com/u-boot/u-boot/archive/refs/tags/${U_BOOT_VERSION}.tar.gz" \
      | tar -xz -C /u-boot/src --strip-components=1

# ---------------------------------------------------------------------------
# U-Boot build: every defconfig of the SoC group, reusing the shared blobs.
# ---------------------------------------------------------------------------
FROM base AS u-boot-builder
ARG U_BOOT_VERSION
ARG RKBIN_REF
ARG SOURCE_DATE_EPOCH
ARG SOC
ARG DEFCONFIGS
ARG OPTEE
ARG CONFIG_FRAGMENTS
ARG VARIANT_SUFFIX

COPY --from=u-boot-source /u-boot/src /u-boot/src
COPY --from=ddr /ddr /ddr
COPY --from=bl31 /bl31 /bl31
COPY --from=tee /optee /optee
COPY --from=fragments / /fragments
COPY scripts/build-uboot.sh /usr/local/bin/build-uboot.sh

ENV BL31=/bl31/bl31.elf
ENV ARCH=arm64
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}

WORKDIR /u-boot/src
RUN --mount=type=cache,target=/root/.cache/ccache \
    SOC="${SOC}" DEFCONFIGS="${DEFCONFIGS}" OPTEE="${OPTEE}" \
    U_BOOT_VERSION="${U_BOOT_VERSION}" RKBIN_REF="${RKBIN_REF}" \
    CONFIG_FRAGMENTS="${CONFIG_FRAGMENTS}" VARIANT_SUFFIX="${VARIANT_SUFFIX}" \
    build-uboot.sh

# ---------------------------------------------------------------------------
# Export stage — `--output type=local,dest=.` writes the binaries and manifest
# to the build context. No OCI image is published; releases ship the .bin.
# ---------------------------------------------------------------------------
FROM scratch AS export
COPY --from=u-boot-builder /u-boot/out/* /
