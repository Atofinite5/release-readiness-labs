#!/usr/bin/env bash
# Deploys the release described in release/release.json to the production cluster.
#
# Safe by default: DRY_RUN=true prints the plan and changes nothing. The pipeline only
# sets DRY_RUN=false when the "production" environment has DEPLOY_ENABLED=true.
#
# Live mode requires: kubectl access to the cluster (KUBECONFIG), and the env vars
# API_KEY and DATABASE_PASSWORD (injected from GitHub Environment secrets, never from files).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN="${DRY_RUN:-true}"
NAMESPACE="${NAMESPACE:-default}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
GIT_SHA="${GIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"

VERSION="$(jq -r '.Version // empty' release/release.json)"
IMAGE="$(jq -r '.Image // empty' release/release.json)"

# Guard: only an explicit, immutable MAJOR.MINOR.PATCH release may be deployed.
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: refusing to deploy: release/release.json Version '${VERSION}' is not MAJOR.MINOR.PATCH (\"latest\" is not allowed)." >&2
  exit 1
fi
if [[ "$IMAGE" != *":${VERSION}" ]]; then
  echo "ERROR: refusing to deploy: image '${IMAGE}' does not carry release version ${VERSION}." >&2
  exit 1
fi

echo "Starting deployment..."
echo "Deploying version: ${VERSION}"
echo "Image:             ${IMAGE}"
echo "Commit:            ${GIT_SHA}"
echo "Namespace:         ${NAMESPACE}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "DRY RUN - the following would happen (nothing is changed):"
  echo "  1. create/update Secret orderflow-secrets from API_KEY and DATABASE_PASSWORD"
  echo "  2. kubectl apply -f deployment/kubernetes/   (image ${IMAGE})"
  echo "  3. kubectl rollout status deployment/orderflow --timeout=${ROLLOUT_TIMEOUT}"
  echo "  4. on a failed rollout: scripts/rollback.sh (automatic)"
  echo "Dry run complete."
  exit 0
fi

command -v kubectl >/dev/null || { echo "ERROR: kubectl not found" >&2; exit 1; }
: "${API_KEY:?API_KEY must be provided as an environment secret}"
: "${DATABASE_PASSWORD:?DATABASE_PASSWORD must be provided as an environment secret}"

# printf is a shell builtin, so the secret values never appear in a process argument list.
printf 'API_KEY=%s\nDATABASE_PASSWORD=%s\n' "$API_KEY" "$DATABASE_PASSWORD" \
  | kubectl -n "$NAMESPACE" create secret generic orderflow-secrets \
      --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | kubectl -n "$NAMESPACE" apply -f -

kubectl -n "$NAMESPACE" apply -f deployment/kubernetes/
kubectl -n "$NAMESPACE" annotate deployment/orderflow \
  kubernetes.io/change-cause="release ${VERSION} (${GIT_SHA})" --overwrite

if ! kubectl -n "$NAMESPACE" rollout status deployment/orderflow --timeout="$ROLLOUT_TIMEOUT"; then
  echo "ERROR: rollout of ${VERSION} did not become ready - rolling back automatically." >&2
  "$ROOT/scripts/rollback.sh"
  exit 1
fi

echo "Deployment successful."
