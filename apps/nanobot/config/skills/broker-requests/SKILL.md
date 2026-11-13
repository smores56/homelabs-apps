---
name: broker-requests
description: Call an external service through the broker; you never hold the credential.
metadata: {"nanobot":{"requires":{"bins":["curl"]}}}
---

# Broker requests

Every outbound request goes to `$BROKER_URL` (the broker Service in the
`broker` namespace). It is an HTTP API, not a proxy: the first path segment is
the **logical host**, the rest is the upstream path, and the query string passes
through untouched.

| Logical host | What it is |
|---|---|
| `neuralwatt` | the model API (`/v1/...`) |
| `github-apps` | git smart HTTP for `smores56/homelabs-apps` |
| `github-platform-push` | git smart HTTP for `smores56/homelabs-platform` (`agent/*` branches only) |
| `github-platform` | the GitHub REST API for pull-request calls |
| `tinyfish` | TinyFish search (`?query=...`) |
| `loki` | the read-only LogQL gateway for the `data` tenant |
| `status` | the cluster status exporter (`/metrics`) |

```sh
curl -sS --max-time 30 "$BROKER_URL/neuralwatt/v1/models"
curl -sS --max-time 20 --get --data-urlencode "query=QUERY" "$BROKER_URL/tinyfish"
curl -sS "$BROKER_URL/status/metrics"
```

The broker strips any `Authorization`, `Cookie`, `X-Api-Key` or
`X-Scope-OrgID` you send and injects the enrolled one. Do not put a token in a
file, an environment variable or a command line: there is none to put, and CI
rejects token-shaped strings.

Refusals are deliberate and not retryable:

- `403 address_refused` / `502 dns_failure`: the target failed the address
  policy; report it, do not try another spelling of the host.
- `502 cross_host_redirect`: the upstream tried to send you elsewhere; stop.
- `405 connect_not_allowed`: no CONNECT, no forward proxy.
- `404 unknown_logical_host`: that host is not enrolled; ask the human.
