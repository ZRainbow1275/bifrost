# Bifrost Server B Verdaccio configuration.
# Rendered by scripts/server-b.sh --enable-distribution.

storage: /verdaccio/storage
url_prefix: /
listen: 0.0.0.0:4873

auth:
  htpasswd:
    file: /verdaccio/storage/htpasswd
    max_users: -1

uplinks:
  npmjs:
    url: https://registry.npmjs.org/
    timeout: 30s
    cache: true

packages:
  '@*/*':
    access: $all
    publish: $authenticated
    proxy: npmjs
  '**':
    access: $all
    publish: $authenticated
    proxy: npmjs

server:
  keepAliveTimeout: 60

log:
  type: stdout
  format: pretty-timestamped
  level: warn
