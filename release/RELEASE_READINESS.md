# OrderFlow v2.3.0 - Release Readiness Pack

| | |
|---|---|
| **Application** | OrderFlow |
| **Release** | **2.3.0** (tag `v2.3.0`) |
| **Target environment** | production |
| **Status** | Release candidate - **awaiting production approval** |
| **Machine-readable records** | [release.json](release.json) - [deployment-config.yml](deployment-config.yml) - [rollback.yml](rollback.yml) - [approvals.yml](approvals.yml) - [release-summary.yml](release-summary.yml) |

---

## 1. Release version

| | |
|---|---|
| Version | `2.3.0` (semantic version, MAJOR.MINOR.PATCH) |
| Git tag | `v2.3.0` - create on the approved commit after merge to `main` |
| Container image | `orderflow:2.3.0` - immutable tag; `latest` and `production-build` are forbidden |
| Previous version | `1.0.0` (rollback target, see section 3) |
| Release date | 2026-11-05 |
| Source of truth | [`release/release.json`](release.json) |

**Traceability.** Every artifact maps back to one version and one commit:

```
git tag v2.3.0 -> commit SHA -> CI run -> image orderflow:2.3.0
   image label  org.opencontainers.image.version / .revision
   running pod  GET /health -> {"status":"ok","version":"2.3.0","commit":"<sha>"}
   CI artifact  release-manifest.json (version, image id, commit, ref, run id; kept 90 days)
```

`scripts/validate-release.sh` fails the pipeline if the version differs between `release.json`,
`package.json`, `package-lock.json`, `release-summary.yml`, `deployment-config.yml`, the image tag
and the Kubernetes manifest (image and labels), so the version cannot drift.

## 2. Deployment strategy

**Pipeline** ([`.github/workflows/release.yml`](../.github/workflows/release.yml)) - each stage must
succeed before the next starts:

| # | Job | What it proves | Runs on |
|---|---|---|---|
| 1 | `validate-release` | locked install, tests, `npm audit`, script syntax, release-config validation | every push / PR |
| 2 | `build-image` (needs 1) | image builds, `/health` reports the right version and commit, manifest recorded | every push / PR |
| 3 | `deploy-production` (needs 1 and 2) | deploys; **pauses for reviewer approval** (`production` environment) | push to `main` only |

**Rollout.** Kubernetes `RollingUpdate`, 3 replicas, `maxUnavailable: 0`, `maxSurge: 1`: old pods keep
serving until new pods pass the readiness probe (`/health`). If the rollout is not ready within 300s,
`scripts/deploy.sh` rolls back automatically.

**Secrets.** No secret values in the repository. Config lists secret *names* only; values come from the
GitHub `production` Environment secrets (`API_KEY`, `DATABASE_PASSWORD`) and are written to the
Kubernetes Secret `orderflow-secrets`; pods read them with `secretKeyRef`. AWS access uses short-lived
OIDC credentials, not static keys.

**Safe by default.** `deploy.sh` is a dry run unless the `production` environment sets the variable
`DEPLOY_ENABLED=true` (together with `AWS_ROLE_ARN`, `AWS_REGION`, `EKS_CLUSTER_NAME`). It refuses to
deploy `latest` or any non-semver version.

## 3. Rollback strategy

| | |
|---|---|
| **Primary** | `./scripts/rollback.sh` -> `kubectl rollout undo deployment/orderflow` (previous ReplicaSet; `revisionHistoryLimit: 10`) |
| **Fallback** | `./scripts/rollback.sh 1.0.0` -> pin the known-good image `orderflow:1.0.0` |
| **Automatic trigger** | rollout not ready within 300s |
| **Manual triggers** | failing `/health` or wrong version after deploy; error-rate/latency regression; release manager decision |
| **Verify** | `kubectl rollout status deployment/orderflow`, then `GET /health` shows the target version |
| **Data** | no database migrations exist in this repository, so no data restore is needed |

Caveat: an explicit-version rollback changes the live image only; the manifests in git still describe
2.3.0, so a later `kubectl apply` rolls forward again. Fix forward in git or revert the release commit.
Full plan: [`rollback.yml`](rollback.yml).

## 4. Infrastructure decision

**Decision: run OrderFlow on Kubernetes (Amazon EKS), 3 nodes across at least 2 availability zones.
The single EC2 `t2.micro` instance previously defined in Terraform is rejected for production.**

| Option | Verdict | Reason |
|---|---|---|
| Single EC2 `t2.micro` (previous Terraform) | Rejected | Single point of failure, no multi-AZ; no rolling update or `rollout undo`, so the safe-deploy and rollback design cannot work; 1 GiB burstable instance is undersized; hard-coded AMI |
| **Amazon EKS** (chosen) | **Accepted** | The app is already containerised and the repo already ships Kubernetes manifests (3 replicas, probes, rolling update); gives zero-downtime deploys and one-command rollback; nodes spread over AZs |
| ECS/Fargate | Viable alternative, not chosen | Would also give rolling deploys, but requires rewriting the existing manifests and rollback tooling |

Consequences: EKS has a control-plane fee and needs cluster operations skills. Terraform is in
[`deployment/terraform`](../deployment/terraform) (validated with `terraform validate`); it needs
`subnet_ids` (>= 2 AZs) and `kubernetes_version` (deliberately no default - pick a version currently in
EKS standard support). Remote state backend and the VPC are not defined here and must be supplied.

## 5. Production approval checklist

Enforced by the GitHub `production` Environment (required reviewers). Record: [`approvals.yml`](approvals.yml).

- [x] Tests pass (`npm test`)
- [x] Release configuration validated (`scripts/validate-release.sh`)
- [x] Image builds and passes the `/health` smoke test
- [x] One release version across code, config, image and manifests
- [x] No plaintext secrets or floating image tags in the repository
- [x] Rollback strategy and target version documented
- [ ] `production` environment configured with required reviewers
- [ ] Environment secrets `API_KEY` and `DATABASE_PASSWORD` created
- [ ] Rollback target `1.0.0` confirmed against what is actually running in production
- [ ] **Engineering Manager approval recorded** (`approvedBy`, `reviewDate`, `releaseManager` in `approvals.yml` are `PENDING`)

## 6. Deployment validation summary

Checks run locally on the release candidate:

| Check | Result |
|---|---|
| `npm ci` + `npm test` (Node 24) | pass - 2/2 tests |
| `npm audit --omit=dev --audit-level=high` | pass - 0 vulnerabilities |
| `scripts/validate-release.sh` | pass |
| `actionlint` on the workflow | pass |
| `shellcheck` on `scripts/*.sh` | pass |
| `terraform fmt` + `init` + `validate` | pass |
| Docker build + `/health` smoke test | pass - reports version `2.3.0` and the build commit |
| Container runs as non-root; SIGTERM shuts down cleanly | pass (uid 1000; exit 0) |

Checks run by GitHub Actions on the release candidate (commit `9e34b2c`, branch
`investigation/release-readiness`) - [run 41970560377](https://github.com/Atofinite5/release-readiness-labs/actions/runs/41970560377):

| Job | Result |
|---|---|
| `validate-release` | success - locked install, tests, audit, script syntax, release-config validation |
| `build-image` | success - image built, `/health` smoke test passed, release manifest uploaded |
| `deploy-production` | skipped - by design, it runs only for pushes to `main` after reviewer approval |

The commit after `9e34b2c` pins the runner image to `ubuntu-24.04` (the `ubuntu-latest` label was announced
to migrate to Ubuntu 26) and records this summary; the pipeline re-runs on it - see the Actions tab.

Also exercised locally: the `deploy.sh` dry run, its refusal to deploy `latest` or an image/version
mismatch, and the `rollback.sh` dry runs (previous revision and explicit version).

**Not verified (cannot be, in this repository):** a live deployment; the live rollback path (the
`kubectl` commands are unexecuted - only the dry-run paths and guards were exercised); the
`deploy-production` job itself and the reviewer approval gate (they need a push to `main` and a
configured `production` environment); and the EKS apply (`terraform validate` checks syntax, not that
the plan applies in your AWS account).

## 7. Risks found and how they were fixed

| # | Finding (before) | Risk | Fix |
|---|---|---|---|
| 1 | `deploy-production` ran first, with no checks; validation ran *after* deploy | Unvalidated code reaches production | Order is now validate -> build -> deploy; deploy `needs` both |
| 2 | Validation job ended with a hard-coded `exit 1` | Pipeline could never pass; failures were not real signal | Removed; real checks gate each stage |
| 3 | Deploy on every push to `main`, no approval | No human gate on production | Deploy job targets the `production` Environment (required reviewers), `main` only |
| 4 | `npm test` just echoed "passed" | Tests could never fail | Real tests of `/` and `/health` (`node --test`) |
| 5 | Plaintext passwords/tokens in `deployment-config.yml`, the Kubernetes manifest and Terraform (`default` on a secret variable) | Credential leak, visible in git history | Removed; `secretKeyRef` + GitHub Environment secrets; `scripts/validate-release.sh` blocks regressions |
| 6 | Image `production-build`, version `latest`, `release.json` v1.0 / `package.json` 1.0.0 | Artifacts untraceable, rollback impossible | Single version 2.3.0 enforced everywhere; immutable tag; commit in image label and `/health` |
| 7 | `rollback.yml` empty, `rollback.sh` a stub | No way back | Documented strategy, executable `rollback.sh`, automatic rollback on a failed rollout |
| 8 | Single EC2 `t2.micro` in Terraform | Single point of failure; incompatible with the manifests | EKS (section 4) |
| 9 | `approvals.yml` empty | No approval record | Pending record + checklist (section 5) |
| 10 | Unpinned actions (`@v3`), floating `ubuntu-latest`, no `permissions`, no timeouts | Supply-chain and over-privilege risk; runner changes without a commit | Actions pinned to commit SHAs, runner pinned to `ubuntu-24.04`, `contents: read`, timeouts, no persisted credentials |
| 11 | Node 18 image (end-of-life), root user, `npm install`, `npm start` as PID 1 | Unpatched runtime; slow/unclean shutdowns | Node 24 LTS, non-root, `npm ci`, `node` as PID 1 with SIGTERM handler, healthcheck |

**Action required if the removed credentials were ever real:** they remain in git history. Rotate them;
removing them from the working tree does not un-leak them.
