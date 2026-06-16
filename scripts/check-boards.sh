#!/bin/sh
# Verify boards.json against the U-Boot version pinned in the Dockerfile:
# every listed defconfig must still exist upstream, and any ARM64 Rockchip
# defconfig upstream that we don't list is reported (non-fatal). Uses the
# GitHub API (needs `gh` + GH_TOKEN); no checkout of U-Boot required.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
boards="${1:-${root}/boards.json}"

tag="$(sed -n 's/^ARG U_BOOT_VERSION=\(.*\)/\1/p' "${root}/Dockerfile")"
[ -n "${tag}" ] || { echo "could not read U_BOOT_VERSION from Dockerfile" >&2; exit 1; }
echo "Validating $(basename "${boards}") against U-Boot ${tag}"

# Structural schema: every SoC must carry the build fields its kinds require, so
# a malformed boards.json fails here rather than mid-build with a "FROM …-null".
jq -e '.socs | length > 0 and all(.[];
  .soc and (.boards | length > 0) and all(.boards[]; .defconfig)
  and (.ddr.kind | . == "rkbin" or . == "uboot")
  and (.ddr.kind != "rkbin" or (.ddr.subdir and .ddr.glob))
  and (.bl31.kind | . == "tfa" or . == "rkbin")
  and (.bl31.kind != "tfa" or .bl31.plat)
  and (.bl31.kind != "rkbin" or .bl31.glob))' "${boards}" >/dev/null \
  || { echo "::error::boards.json failed structural validation" >&2; exit 1; }

configs_sha="$(gh api "repos/u-boot/u-boot/git/trees/${tag}" -q '.tree[] | select(.path=="configs") | .sha')"
[ -n "${configs_sha}" ] || { echo "could not locate configs/ tree at ${tag}" >&2; exit 1; }
upstream="$(gh api "repos/u-boot/u-boot/git/trees/${configs_sha}" -q '.tree[].path' | sed -n 's/_defconfig$//p')"

listed="$(jq -r '.socs[].boards[].defconfig' "${boards}")"

missing=""
for dc in ${listed}; do
  printf '%s\n' "${upstream}" | grep -qx "${dc}" || missing="${missing} ${dc}"
done

# rk3368 (geekbox, evb-px5, sheep-rk3368) is intentionally excluded: it predates
# the binman u-boot-rockchip.bin flow and ships the older idbloader/u-boot.img
# images, which this repo does not package.
excluded="geekbox evb-px5 sheep-rk3368"
new=""
for dc in $(printf '%s\n' "${upstream}" | grep -E -- '-(rk3588s?|rk3576|rk3568|rk3566|rk3528|rk3399pro|rk3399|rk3328|rk3308|rk3326|px30)$'); do
  printf '%s\n' "${listed}" | grep -qx "${dc}" && continue
  printf '%s\n' "${excluded}" | grep -qw "${dc}" && continue
  new="${new} ${dc}"
done

status=0
if [ -n "${missing}" ]; then
  echo "::error::defconfigs in boards.json missing from U-Boot ${tag}:${missing}"
  status=1
fi
if [ -n "${new}" ]; then
  echo "::warning::ARM64 Rockchip defconfigs in U-Boot ${tag} not listed in boards.json:${new}"
fi
if [ "${status}" = 0 ]; then
  echo "OK: all $(printf '%s\n' "${listed}" | grep -c .) listed defconfigs exist in ${tag}"
fi
exit ${status}
