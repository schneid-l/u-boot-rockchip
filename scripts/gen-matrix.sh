#!/bin/sh
# Expand boards.json into a GitHub Actions build matrix: one job per SoC group
# (standard), plus one extra job per OP-TEE-capable SoC (the -optee variant).
set -eu
boards="${1:-boards.json}"

jq -c '
  # Right-size the runner to the SoC board count: a 1-board SoC does not need
  # 16 cores. Big SoCs keep 16 so they do not become the wall-clock long pole.
  def runner($n):
    if $n > 20 then "ubicloud-standard-16-arm"
    elif $n > 6 then "ubicloud-standard-8-arm"
    else "ubicloud-standard-4-arm" end;
  def entry($s; $optee):
    { soc: $s.soc,
      title: ($s.soc + (if $optee then " + OP-TEE" else "" end)),
      runner: runner($s.boards | length),
      defconfigs: ([$s.boards[].defconfig] | join(" ")),
      ddr_kind: $s.ddr.kind,
      ddr_subdir: ($s.ddr.subdir // ""),
      ddr_glob: ($s.ddr.glob // ""),
      bl31_kind: $s.bl31.kind,
      atf_plat: ($s.bl31.plat // ""),
      atf_track: ($s.bl31.version // "modern"),
      bl31_glob: ($s.bl31.glob // ""),
      optee: (if $optee then "on" else "off" end),
      suffix: (if $optee then "-optee" else "" end),
      optee_platform: ($s.optee_platform // "") };
  { include: [ .socs[]
      | entry(.; false),
        (select(.optee_platform != null) | entry(.; true)) ] }
' "$boards"
