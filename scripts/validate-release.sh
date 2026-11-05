#!/usr/bin/env bash
# Static release-readiness gate. Exits non-zero if the repository is not safe to release.
# Runs in CI (validate job) before anything is built or deployed; also runnable locally.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }

failures=0
pass() { echo "ok:   $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# --- 1. One version, everywhere ---------------------------------------------------------
VERSION="$(jq -r '.Version // empty' release/release.json)"
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "release/release.json Version is MAJOR.MINOR.PATCH ($VERSION)"
else
  fail "release/release.json Version '$VERSION' is not MAJOR.MINOR.PATCH"
fi

expect_version() { # <label> <actual>
  if [[ "$2" == "$VERSION" ]]; then pass "$1 = $VERSION"; else fail "$1 is '$2', expected $VERSION"; fi
}
yaml_value() { sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1 | tr -d '"'; }

expect_version "app/package.json version"            "$(jq -r '.version' app/package.json)"
expect_version "app/package-lock.json version"       "$(jq -r '.version' app/package-lock.json)"
expect_version "release.json GitTag"                 "$(jq -r '.GitTag' release/release.json | sed 's/^v//')"
expect_version "release.json Image tag"              "$(jq -r '.Image' release/release.json | cut -d: -f2)"
expect_version "release-summary.yml version"         "$(yaml_value version release/release-summary.yml)"
expect_version "deployment-config.yml version"       "$(yaml_value version release/deployment-config.yml)"
expect_version "deployment-config.yml image tag"     "$(sed -n 's/^  tag:[[:space:]]*//p' release/deployment-config.yml | head -1 | tr -d '"')"
expect_version "kubernetes deployment image tag"     "$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' deployment/kubernetes/deployment.yaml | head -1 | cut -d: -f2)"
while IFS= read -r label_version; do
  expect_version "kubernetes version label" "$label_version"
done < <(grep -o 'app.kubernetes.io/version: "[^"]*"' deployment/kubernetes/deployment.yaml | cut -d'"' -f2)

# --- 2. No floating image tags ----------------------------------------------------------
CONFIG_FILES="$(find release deployment .github -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.tf' -o -name '*.json' \)) docker-compose.yml Dockerfile"
# shellcheck disable=SC2086 # intentional word splitting over a list of plain paths
if grep -En '(image|tag|version):[[:space:]]*"?(latest|production-build)"?([[:space:]]|$)|:(latest|production-build)([[:space:]"]|$)' $CONFIG_FILES; then
  fail "floating image tag/version (latest, production-build) found above"
else
  pass "no floating image tags (latest / production-build)"
fi

# --- 3. No plaintext secrets ------------------------------------------------------------
SECRET_HITS=0
SCAN_FILES="$(find . -type f -not -path './.git/*' -not -path '*/node_modules/*' -not -name package-lock.json -not -name validate-release.sh)"

# 3a. Secret-like variable assigned a literal value (references such as ${X} / $X are fine)
# shellcheck disable=SC2086
if grep -En '^[[:space:]]*-?[[:space:]]*[A-Z0-9_]*(PASSWORD|SECRET|TOKEN|API_?KEY|ACCESS_KEY)[A-Z0-9_]*[[:space:]]*[:=][[:space:]]*"?[^"[:space:]{$#]' $CONFIG_FILES; then
  SECRET_HITS=1
fi
# 3b. Well-known credential formats anywhere in the repo
# shellcheck disable=SC2086
if grep -EnI 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}' $SCAN_FILES; then
  SECRET_HITS=1
fi
# 3c. Kubernetes: a secret-like env var must use secretKeyRef, never a literal `value:`
K8S_FILES="$(find deployment \( -name '*.yaml' -o -name '*.yml' \))"
if [[ -n "$K8S_FILES" ]]; then
  # shellcheck disable=SC2086
  K8S_HITS="$(awk '
    toupper($0) ~ /NAME:[[:space:]]*"?[A-Z0-9_]*(PASSWORD|SECRET|TOKEN|KEY)[A-Z0-9_]*"?[[:space:]]*$/ { pending = FILENAME ":" FNR; next }
    pending != "" { if ($0 ~ /^[[:space:]]*value:/) print pending ": secret-like env var has a literal value"; pending = "" }
  ' $K8S_FILES)"
  if [[ -n "$K8S_HITS" ]]; then echo "$K8S_HITS"; SECRET_HITS=1; fi
fi
# 3d. Terraform: a secret-like variable must not have a default
TF_FILES="$(find deployment -name '*.tf')"
if [[ -n "$TF_FILES" ]]; then
  # shellcheck disable=SC2086
  TF_HITS="$(awk '
    toupper($0) ~ /^[[:space:]]*VARIABLE[[:space:]]+"[^"]*(SECRET|PASSWORD|TOKEN|KEY)[^"]*"/ { invar = 1; next }
    invar && /^[[:space:]]*default[[:space:]]*=/ { print FILENAME ":" FNR ": secret-like Terraform variable has a default value" }
    /^}/ { invar = 0 }
  ' $TF_FILES)"
  if [[ -n "$TF_HITS" ]]; then echo "$TF_HITS"; SECRET_HITS=1; fi
fi
if [[ $SECRET_HITS -eq 0 ]]; then pass "no plaintext secrets in configuration, manifests or Terraform"; else fail "plaintext secret(s) found above"; fi

# --- 4. Rollback plan -------------------------------------------------------------------
STRATEGY_TEXT="$(awk '/^rollback_strategy:/{f=1; sub(/^rollback_strategy:[ ]*/,""); print; next} f&&/^[^ ]/{f=0} f{print}' release/rollback.yml | tr -d '>|[:space:]-')"
ROLLBACK_TARGET="$(yaml_value target_version release/rollback.yml)"
if [[ -n "$STRATEGY_TEXT" ]]; then pass "rollback_strategy is defined"; else fail "release/rollback.yml rollback_strategy is empty"; fi
if [[ "$ROLLBACK_TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$ROLLBACK_TARGET" != "$VERSION" ]]; then
  pass "rollback target_version is a different, explicit version ($ROLLBACK_TARGET)"
else
  fail "release/rollback.yml target_version '$ROLLBACK_TARGET' must be an explicit MAJOR.MINOR.PATCH different from $VERSION"
fi

# --- 5. Approval record and release documentation ---------------------------------------
for key in approvedBy reviewDate releaseManager; do
  if grep -Eq "^${key}:" release/approvals.yml; then pass "approvals.yml has '$key'"; else fail "release/approvals.yml is missing '$key'"; fi
done
PACK=release/RELEASE_READINESS.md
if [[ -f "$PACK" ]]; then
  for section in "Release version" "Deployment strategy" "Rollback strategy" "Infrastructure decision" "Production approval checklist" "Deployment validation summary"; do
    if grep -Eiq "^##[[:space:]]+[0-9.]*[[:space:]]*${section}" "$PACK"; then pass "release pack section: $section"; else fail "$PACK is missing section: $section"; fi
  done
else
  fail "$PACK does not exist"
fi

echo
if [[ $failures -eq 0 ]]; then
  echo "Release validation PASSED for OrderFlow $VERSION"
else
  echo "Release validation FAILED: $failures problem(s)"
  exit 1
fi
