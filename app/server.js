const express = require('express');
const { version } = require('./package.json');

const app = express();
const port = process.env.PORT || 3000;
// Injected at image build time (Dockerfile ARG GIT_SHA) so a running pod can be
// traced back to the exact commit it was built from.
const commit = process.env.GIT_SHA || 'unknown';

app.disable('x-powered-by');

app.get('/', (req, res) => {
  res.send('Welcome to the Release Readiness Lab API');
});

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'ok', version, commit });
});

if (require.main === module) {
  const server = app.listen(port, () => {
    console.log(`OrderFlow v${version} (${commit}) listening on port ${port}`);
  });

  // Kubernetes sends SIGTERM on rollout/rollback. Without a handler, node running
  // as PID 1 ignores it and the pod is SIGKILLed after the grace period.
  process.on('SIGTERM', () => {
    console.log('SIGTERM received, shutting down');
    server.close(() => process.exit(0));
  });
}

module.exports = app;
