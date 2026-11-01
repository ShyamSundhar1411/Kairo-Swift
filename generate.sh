#!/usr/bin/env bash
# Generates Kairo.xcodeproj.
#
# Signing lives in mobile/signing.env, which is committed so the team can clone
# and hit run. It is read here rather than written into the spec directly because
# XcodeGen leaves an unset ${KAIRO_DEV_TEAM} in the project as a literal string,
# which then fails to build; exporting an empty default keeps that from happening
# if the file is ever missing.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f signing.env ]; then
  # shellcheck disable=SC1091
  set -a; . ./signing.env; set +a
fi
export KAIRO_DEV_TEAM="${KAIRO_DEV_TEAM:-}"
export KAIRO_BUNDLE_SUFFIX="${KAIRO_BUNDLE_SUFFIX:-}"
# Loopback unless told otherwise. Correct in the simulator, which shares the
# Mac's network stack; on a real device loopback is the phone, so a device build
# wants the Mac's LAN address here.
export KAIRO_BACKEND_URL="${KAIRO_BACKEND_URL:-http://127.0.0.1:9080}"

if [ -z "$KAIRO_DEV_TEAM" ]; then
  echo "note: no KAIRO_DEV_TEAM - simulator builds work, a device build will not."
  echo "      Set one in mobile/signing.env."
fi

xcodegen generate
echo
echo "bundle id  au.edu.sydney.elec5620.kairo${KAIRO_BUNDLE_SUFFIX}"
echo "team       ${KAIRO_DEV_TEAM:-none}"
echo "backend    ${KAIRO_BACKEND_URL}"
echo "open with  open Kairo.xcodeproj"
