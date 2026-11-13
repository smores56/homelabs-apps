# nanobot config contract

This directory is the agent's tenant-owned declarative state: skills and cron.
The system prompt and the model catalog are platform-owned and arrive from the
`nanobot-policy` ConfigMap; nothing here may shadow them.

## How it reaches the pod

`apps/nanobot/kustomization.yaml` turns each file into one key of the
`nanobot-config` ConfigMap (kustomize appends a content hash, which rolls the
Deployment on every config change). The Deployment mounts the keys at fixed
paths and sets `NANOBOT_CONFIG_DIR=/etc/nanobot`.

| File | Mount path | Read by |
|---|---|---|
| `cron/*.yaml` | `/etc/nanobot/cron/<name>.yaml` | scheduler, one entry per file |
| `skills/<name>/SKILL.md` | `/etc/nanobot/skills/<name>/SKILL.md` | skill index, YAML front matter |

The prompt (`/etc/nanobot/prompts/system.md`) and the model catalog
(`/etc/nanobot/models/providers.yaml`) are mounted from platform's
`nanobot-policy` ConfigMap at those fixed paths by `subPath` volume mounts.
Admission rejects a nanobot pod that omits or repoints them, and the next
restart restores platform's copy over any runtime edit (smores56/sdlc#639).

The mount is read-only and the container rootfs is read-only. Everything the
agent writes goes to `$HOME` on the `nanobot-scratch` PVC (`/data/home`), to
`/tmp`, or into the library at `/data/books` (the `nanobot-books` PVC, the same
host share Calibre and OPDS read). All of it belongs to uid/gid 1000.

The pod has no credential: `serviceAccountName: nanobot`,
`automountServiceAccountToken: false`, no Secret volume and no Secret-backed
env. The broker is the only place a credential exists and the only reachable
internal service; the images and skills fetch public content directly (the
network contract in `apps/nanobot/networkpolicy.yaml` excepts every private
range). `BROKER_URL` is still the only address that carries a token.

## Image-side contract

The image's entrypoint renders, on start (owned by `homelabs-platform`):

1. `$HOME/.nanobot/config.json` — `providers.<neuralwatt>.api_base`,
   `agents.defaults` (provider, default model, context window, output cap) and
   one `modelPresets` entry per catalog model;
2. the platform policy's `prompts/system.md` → the workspace `AGENTS.md` (the
   system prompt's project-instructions slot);
3. every directory under `$NANOBOT_CONFIG_DIR/skills` → the workspace `skills/`;
4. `cron/*.yaml` → the workspace `cron/jobs.json` (session-bound `agent_turn`
   jobs, delivery `file` only);
5. refuses to start if a file is missing or unparsable, rather than falling back
   to a default model.

Nothing below the mount is copied back into Git. Skills and cron are proposed by
committing them here; the prompt and model catalog are changed only in
`homelabs-platform`.

## Rules for edits

- No credentials, tokens, emails, or personal data in any file here. A
  token-shaped string fails `scripts/policy-scan.sh`; there is no legitimate
  token for the agent to hold, including a broker token.
- A model id comes from the Neuralwatt catalog in platform's
  `models/providers.yaml`; a tenant file cannot change it. New ids arrive in
  `homelabs-platform`, not on their own.
- A cron entry stays under 20 lines, writes a file under `/data/outbox`
  (`delivery: {kind: file, path: /data/outbox/...}`; any other kind fails the
  start), and names a `model`. nanobot 0.4.1 has no per-job model override, so
  the renderer requires that model to equal `models.default` and refuses a
  mismatch rather than silently running the default. It never sends anything
  outward. `/data/outbox` is
  on the scratch PVC and **nothing reads it**: it is the agent's own scratch
  record, not a delivery channel. The cluster digest the cluster sends toward
  Kanbei is written by the platform CronJob (`cluster-digest` in
  `homelabs-platform`) to the host's share and age-encrypted by the host writer;
  the agent neither produces nor consumes it.
- A skill is one action, one `SKILL.md`, and any binary it needs must already
  exist in the image (`metadata.nanobot.requires.bins`). Every credentialed
  outbound call names a broker logical host (`skills/broker-requests`); a public
  download may go direct, and never carries a token.
