# hello-world-skill

Smoke-test skill for the bifrost-internal marketplace.

## Install

```
/plugin install hello-world-skill@bifrost-internal
```

## Invoke

The skill registers a single capability under the name `hello`. Trigger it
from any Claude Code session that has the bifrost-internal marketplace
enabled, and it will respond with `Hello from bifrost-internal!`.

## Versioning

Releases are cut by the admin panel upload flow (panel.uuhfn.cloud ->
`/marketplace/admin/upload`), which creates an annotated tag of the form
`plugins/hello-world-skill/v<X.Y.Z>`. The `version` field in `manifest.yaml`
must match that semver exactly or `render-marketplace-json.sh` will exit 3.
