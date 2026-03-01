# Repository Contents

## Scripts

- **[scripts/mirror-images-to-registry.sh](../scripts/mirror-images-to-registry.sh)** - Mirror Che images to cluster local registry
- **[scripts/deploy-che-from-bundles.sh](../scripts/deploy-che-from-bundles.sh)** - Manual operator deployment from OLM bundles (runs all fixes automatically)
- **[scripts/ensure-deployment-ready.sh](../scripts/ensure-deployment-ready.sh)** - Post-deploy verification: runs fix-image-pulls + fix-oauth-redirect, waits for webhook endpoints (run if login or workspace create fails)
- **[scripts/fix-image-pulls.sh](../scripts/fix-image-pulls.sh)** - Patch CheCluster and deployments to use local registry (prevents InstallOrUpdateFailed, workspace webhook)
- **[scripts/fix-oauth-redirect.sh](../scripts/fix-oauth-redirect.sh)** - Fix OAuth redirect URI mismatch (prevents login "invalid_request" error)
- **[scripts/provision-che-server-manually.sh](../scripts/provision-che-server-manually.sh)** - Fallback: provision che-server when operator fails (fixes "Route POST:/api/kubernetes/namespace/provision not found")
- **[scripts/test-ipv6-validation.sh](../scripts/test-ipv6-validation.sh)** - Deploy devfile server for IPv6 testing; `--cleanup` removes test namespace
- **[scripts/che-proxy-pac-helper.sh](../scripts/che-proxy-pac-helper.sh)** - Generate PAC file and Chrome proxy command for ostest
