#!/usr/bin/env bash
# Rolls the production deployment back. See release/rollback.yml for the full plan.
#
#   ./scripts/rollback.sh            undo to the previous revision (kubectl rollout undo)
#   ./scripts/rollback.sh 1.0.0      redeploy an explicit known-good version
#
# DRY_RUN=true previews the action without changing anything.
# Note: an explicit-version rollback changes the live image only; the manifests in git still
# describe the newer release, so a later `kubectl apply` would roll forward again.
set -euo pipefail

TARGET_VERSION="${1:-${TARGET_VERSION:-}}"
DRY_RUN="${DRY_RUN:-false}"
NAMESPACE="${NAMESPACE:-default}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

echo "Rolling back deployment..."

if [[ -n "$TARGET_VERSION" ]]; then
  if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: target version '${TARGET_VERSION}' must be MAJOR.MINOR.PATCH (\"latest\" is not allowed)." >&2
    exit 1
  fi
  ACTION=(kubectl -n "$NAMESPACE" set image deployment/orderflow "orderflow=orderflow:${TARGET_VERSION}")
  echo "Target: orderflow:${TARGET_VERSION}"
else
  ACTION=(kubectl -n "$NAMESPACE" rollout undo deployment/orderflow)
  echo "Target: previous revision"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY RUN - would run: ${ACTION[*]}"
  echo "DRY RUN - would then wait for: kubectl rollout status deployment/orderflow --timeout=${ROLLOUT_TIMEOUT}"
  exit 0
fi

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }

"${ACTION[@]}"
kubectl -n "$NAMESPACE" rollout status deployment/orderflow --timeout="$ROLLOUT_TIMEOUT"
echo "Rollback complete. Verify GET /health reports the expected version."
