#!/bin/sh
# Build every defconfig of one SoC group, reusing the shared BL31, DDR (TPL)
# and (optional) OP-TEE blobs prepared by earlier Dockerfile stages. Inputs are
# passed as environment variables; outputs land in /u-boot/out.
set -eu

: "${DEFCONFIGS:?}" "${SOC:?}" "${U_BOOT_VERSION:?}" "${RKBIN_REF:?}"
OPTEE="${OPTEE:-off}"

export CCACHE_DIR=/root/.cache/ccache
export PATH="/usr/lib/ccache:${PATH}"
# Bounded so the cross-run cache stays small enough to persist cheaply.
ccache -M 500M >/dev/null 2>&1 || true

variant=""
[ "${OPTEE}" = "on" ] && variant="-optee"
[ -f /optee/tee.elf ] && export TEE=/optee/tee.elf
# Present only when DDR_KIND=rkbin; otherwise U-Boot builds its own TPL.
[ -f /ddr/tpl.bin ] && export ROCKCHIP_TPL=/ddr/tpl.bin

out=/u-boot/out
build=/tmp/build
mkdir -p "${out}"
jobs="$(nproc)"
binaries=""

for dc in ${DEFCONFIGS}; do
  echo "==> building ${dc}${variant}"
  rm -rf "${build}"
  mkdir -p "${build}"
  make O="${build}" -j"${jobs}" "${dc}_defconfig" >/dev/null
  make O="${build}" -j"${jobs}" HOSTLDLIBS_mkimage="-lssl -lcrypto"

  found=0
  for f in "${build}"/u-boot-rockchip*.bin; do
    [ -e "${f}" ] || continue
    medium="$(basename "${f}")"
    medium="${medium#u-boot-rockchip}"   # "" (SD/eMMC) or "-spi"
    medium="${medium%.bin}"
    name="u-boot-${dc}${variant}${medium}.bin"
    cp "${f}" "${out}/${name}"
    binaries="${binaries} ${name}"
    found=1
  done
  [ "${found}" = 1 ] || { echo "ERROR: ${dc} produced no u-boot-rockchip*.bin" >&2; exit 1; }
done

json_array() {
  printf '['
  sep=''
  for item in $1; do
    printf '%s"%s"' "${sep}" "${item}"
    sep=', '
  done
  printf ']'
}

# shellcheck disable=SC1091 # /etc/os-release is a runtime file, not in the repo
ubuntu_version="$(. /etc/os-release && echo "${VERSION_ID}")"

cat > "${out}/u-boot-${SOC}${variant}.manifest.json" <<EOF
{
  "soc": "${SOC}",
  "variant": "$([ "${OPTEE}" = "on" ] && echo optee || echo standard)",
  "u_boot_version": "${U_BOOT_VERSION}",
  "bl31_source": "$(cat /bl31/bl31.source)",
  "bl31_version": "$(cat /bl31/bl31.version)",
  "rkbin_ref": "${RKBIN_REF}",
  "ddr_source": "$(cat /ddr/ddr.source)",
  "ddr_version": "$(cat /ddr/ddr.version)",
  "optee_version": "$(cat /optee/optee.version)",
  "ubuntu_version": "${ubuntu_version}",
  "source_date_epoch": "${SOURCE_DATE_EPOCH:-}",
  "binaries": $(json_array "${binaries}")
}
EOF
