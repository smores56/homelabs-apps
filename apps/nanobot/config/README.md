# nanobot config contract

This directory is the agent's declarative state. It contains no secrets and is
the only source of the agent's behaviour; anything not here is image code.

## How it reaches the pod

`apps/nanobot/kustomization.yaml` turns each file into one key of the
`nanobot-config` ConfigMap (kustomize appends a content hash, which rolls the
Deployment on every config change). The Deployment mounts the keys at fixed
paths and sets `NANOBOT_CONFIG_DIR=/etc/nanobot`.

| File | Mount path | Read by |
|---|---|---|
| `prompts/system.md` | `/etc/nanobot/prompts/system.md` | system prompt, prepended to every session |
| `models/providers.yaml` | `/etc/nanobot/models/providers.yaml` | provider/model catalog and proxy |
| `cron/*.yaml` | `/etc/nanobot/cron/<name>.yaml` | scheduler, one entry per file |
| `skills/<name>/SKILL.md` | `/etc/nanobot/skills/<name>/SKILL.md` | skill index, YAML front matter |

The mount is read-only and the container rootfs is read-only. Everything the
agent writes goes to `$HOME` on the `nanobot-scratch` PVC (`/data/home`) or to
`/tmp`.

The pod has no credential: `serviceAccountName: nanobot`,
`automountServiceAccountToken: false`, no Secret volume and no Secret-backed
env. `BROKER_URL` is the only outbound address, and the broker injects the
provider token (`docs/broker.md` in `homelabs-platform`).

## Image-side contract

The image's entrypoint renders, on start (`pkgs/nanobot/render.py` in
`nix-config`):

1. `$HOME/.nanobot/config.json` — `providers.<neuralwatt>.api_base`,
   `agents.defaults` (provider, default model, context window, output cap) and
   one `modelPresets` entry per catalog model;
2. `prompts/system.md` → the workspace `AGENTS.md` (the system prompt's
   project-instructions slot);
3. every directory under `$NANOBOT_CONFIG_DIR/skills` → the workspace `skills/`;
4. `cron/*.yaml` → the workspace `cron/jobs.json` (session-bound `agent_turn`
   jobs, delivery `file` only);
5. refuses to start if a file is missing or unparsable, rather than falling back
   to a default model.

Nothing below the mount is copied back into Git. The agent may propose edits to
these files by committing them like any other manifest.

## Rules for edits

- No credentials, tokens, emails, or personal data in any file here. A
  token-shaped string fails `scripts/policy-scan.sh`; there is no legitimate
  token for the agent to hold, including a broker token.
- A model id comes from the Neuralwatt catalog in `models/providers.yaml`; new
  ids arrive with their context window and output cap, not on their own.
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
  exist in the image (`metadata.nanobot.requires.bins`). Every outbound call
  names a broker logical host (`skills/broker-requests`).
