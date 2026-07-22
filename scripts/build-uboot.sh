#!/bin/sh
# Build every defconfig of one SoC group, reusing the shared BL31, DDR (TPL)
# and (optional) OP-TEE blobs prepared by earlier Dockerfile stages. Inputs are
# passed as environment variables; outputs land in /u-boot/out.
set -eu

: "${DEFCONFIGS:?}" "${SOC:?}" "${U_BOOT_VERSION:?}" "${RKBIN_REF:?}"
OPTEE="${OPTEE:-off}"
# Optional Kconfig fragments (filenames under /fragments) merged into every
# defconfig, and the suffix that keeps the resulting binaries distinguishable
# from a stock build. Both empty for the standard builds.
CONFIG_FRAGMENTS="${CONFIG_FRAGMENTS:-}"
VARIANT_SUFFIX="${VARIANT_SUFFIX:-}"

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

# Resolve the requested fragments up front, so a typo fails the build before
# anything is compiled rather than after the first board.
fragment_paths=""
for frag in ${CONFIG_FRAGMENTS}; do
  path="/fragments/${frag}"
  [ -f "${path}" ] || { echo "ERROR: no such Kconfig fragment: ${frag}" >&2; exit 1; }
  fragment_paths="${fragment_paths} ${path}"
done

# Kconfig silently drops an assignment whose dependencies are unmet, which
# would produce a binary that builds and boots but is missing exactly the
# feature the fragment asked for. Assert every explicit line survived.
verify_fragments() {
  conf="$1"
  rc=0
  for f in ${fragment_paths}; do
    # Every assignment the fragment makes, minus every line the resolved
    # .config contains, is what Kconfig threw away.
    missing="$(grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)' "${f}" \
               | grep -Fxv -f "${conf}" || true)"
    [ -n "${missing}" ] || continue
    echo "ERROR: ${f}: dropped by olddefconfig (unmet dependency?):" >&2
    echo "${missing}" | sed 's/^/  /' >&2
    rc=1
  done
  return "${rc}"
}

for dc in ${DEFCONFIGS}; do
  echo "==> building ${dc}${variant}"
  rm -rf "${build}"
  mkdir -p "${build}"
  make O="${build}" -j"${jobs}" "${dc}_defconfig" >/dev/null
  if [ -n "${fragment_paths}" ]; then
    # shellcheck disable=SC2086 # fragment_paths is a deliberate word list
    ./scripts/kconfig/merge_config.sh -m -O "${build}" "${build}/.config" ${fragment_paths}
    make O="${build}" -j"${jobs}" olddefconfig >/dev/null
    verify_fragments "${build}/.config"
  fi
  make O="${build}" -j"${jobs}" HOSTLDLIBS_mkimage="-lssl -lcrypto"

  found=0
  for f in "${build}"/u-boot-rockchip*.bin; do
    [ -e "${f}" ] || continue
    medium="$(basename "${f}")"
    medium="${medium#u-boot-rockchip}"   # "" (SD/eMMC) or "-spi"
    medium="${medium%.bin}"
    name="u-boot-${dc}${variant}${VARIANT_SUFFIX}${medium}.bin"
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

# Fragments are recorded by content hash: the filename alone says nothing about
# what was actually merged into the binaries.
fragments_json() {
  printf '['
  sep=''
  for f in ${fragment_paths}; do
    printf '%s{"name": "%s", "sha256": "%s"}' \
      "${sep}" "$(basename "${f}")" "$(sha256sum "${f}" | cut -d' ' -f1)"
    sep=', '
  done
  printf ']'
}

# shellcheck disable=SC1091 # /etc/os-release is a runtime file, not in the repo
ubuntu_version="$(. /etc/os-release && echo "${VERSION_ID}")"

cat > "${out}/u-boot-${SOC}${variant}${VARIANT_SUFFIX}.manifest.json" <<EOF
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
  "variant_suffix": "${VARIANT_SUFFIX}",
  "config_fragments": $(fragments_json),
  "binaries": $(json_array "${binaries}")
}
EOF
