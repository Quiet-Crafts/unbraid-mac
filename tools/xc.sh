#!/bin/bash
# xcodebuild that may create and update signing profiles itself (-allowProvisioningUpdates; UNBRAID_PROVISIONING=0 turns
# that off), through the App Store Connect API key when one is configured (tools/asc.sh), so no Xcode account login is
# needed. Without a key it is plain xcodebuild: Xcode's signed-in account, or your own signing (README.md, Build).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/tools/asc.sh"
asc_load
ARGS=()
[ "${UNBRAID_PROVISIONING:-1}" = 0 ] || ARGS+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
[ "$ASC_READY" = 0 ] || ARGS+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
exec xcodebuild ${ARGS[@]+"${ARGS[@]}"} "$@"
