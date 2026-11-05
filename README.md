# OrderFlow

This repository contains the Release Readiness Investigation & Deployment Approval Lab.

## Application

A simple Node.js Express application.

### Endpoints
- `GET /`
- `GET /health`

## Current Release
v2.3.0 - release candidate for production, awaiting approval.

Release documentation: [release/RELEASE_READINESS.md](release/RELEASE_READINESS.md)
(version, deployment strategy, rollback strategy, infrastructure decision, approval checklist,
validation summary).

Pipeline: `validate-release` -> `build-image` -> `deploy-production` (main only, requires
approval of the `production` environment). Check the release configuration locally with
`bash scripts/validate-release.sh`.

## Getting Started

### Clone
```bash
git clone https://github.com/kalviumcommunity/release-readiness-labs.git
cd release-readiness-labs
```

### Install
```bash
cd app
npm install
```

### Run
```bash
npm start
```
Alternatively, use Docker Compose:
```bash
docker-compose up --build
```

### Push
Make your changes and push them back to the repository.

## Repository Structure
```
├── .github/
│   └── workflows/
│       └── release.yml
├── app/
│   ├── server.js
│   └── package.json
├── deployment/
│   ├── kubernetes/
│   └── terraform/
├── release/            version, approvals, rollback plan, release readiness pack
├── scripts/            deploy.sh, rollback.sh, validate-release.sh
├── Dockerfile
├── docker-compose.yml
└── README.md
```
