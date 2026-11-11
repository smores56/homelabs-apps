---
name: tinyfish-search
description: Search the web through the broker for current results.
metadata: {"nanobot":{"requires":{"bins":["curl"]}}}
---

# TinyFish search

The broker holds the search key, so the request carries no credential. The
query is one argument list, never shell syntax.

```sh
curl -sS --max-time 20 -H 'Accept: application/json' \
  --get --data-urlencode "query=QUERY" "$TINYFISH_BASE_URL"
```

Read `.results[]` and use `title`, `url` and `snippet`. Keep the query under 100
characters: anything longer is dropped by the search budget. On a failure or an
empty result, say so and stop; do not retry in a loop.
