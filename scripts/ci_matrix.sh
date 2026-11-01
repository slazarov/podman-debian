#!/bin/bash

# ci_matrix.sh -- print the build matrix for .github/workflows/build-packages.yml
# as compact JSON, one cell per supported distro:
#
#   [{"distro":"bookworm","container":"docker.io/library/debian:bookworm"},...]
#
# The cells come from the distro table in config.sh (VALID_DISTROS and
# DISTRO_IMAGES), so adding a distro there adds a CI cell. Only that block of
# config.sh is read; the rest (host detection, network calls) is not run.

set -euo pipefail

toolpath="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
eval "$(sed -n '/^VALID_TRACKS=/,/^unset _distro _track$/p' "${toolpath}/config.sh")"

json="["
sep=""
for distro in "${VALID_DISTROS[@]}"; do
    json+="${sep}{\"distro\":\"${distro}\",\"container\":\"${DISTRO_IMAGES[${distro}]}\"}"
    sep=","
done
json+="]"

printf '%s\n' "${json}"
