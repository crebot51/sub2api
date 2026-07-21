# VPS auto-update

Canonical updater on VPS: `/usr/local/bin/sub2api-auto-update`

GitHub Actions workflow `VPS auto-update` SSHes into the VPS daily (23:20 UTC) and runs it.

Required repo secrets:
- `VPS_HOST` (e.g. 45.8.133.232)
- `VPS_SSH_KEY` (private key PEM)
- `VPS_SSH_PORT` (default 58222)
- `VPS_SSH_USER` (default root)
