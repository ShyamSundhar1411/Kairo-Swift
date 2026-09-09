#!/usr/bin/env bash
# Generates Kairo.xcodeproj.
#
# Signing is per-developer, so it is not in the spec directly — it comes from
# mobile/signing.env, which is gitignored. An unset variable would otherwise be
# written into the project as the literal string "${KAIRO_DEV_TEAM}", which
# fails to build for everyone who has not set it.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f signing.env ]; then
  # shellcheck disable=SC1091
  set -a; . ./signing.env; set +a
fi
export KAIRO_DEV_TEAM="${KAIRO_DEV_TEAM:-}"
export KAIRO_BUNDLE_SUFFIX="${KAIRO_BUNDLE_SUFFIX:-}"

if [ -z "$KAIRO_DEV_TEAM" ]; then
  echo "note: no KAIRO_DEV_TEAM — simulator builds work, a device build will need"
  echo "      a team. Copy signing.env.example to signing.env and fill it in."
fi

xcodegen generate
echo
echo "bundle id  au.edu.sydney.elec5620.kairo${KAIRO_BUNDLE_SUFFIX}"
echo "team       ${KAIRO_DEV_TEAM:-none}"
echo "open with  open Kairo.xcodeproj"
