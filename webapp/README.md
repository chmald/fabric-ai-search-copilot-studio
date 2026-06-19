# `webapp/` — Foundry agent web app overlay (OBO)

A **thin configuration overlay** for deploying the Microsoft sample **[microsoft-foundry/foundry-agent-webapp](https://github.com/microsoft-foundry/foundry-agent-webapp)** as a standalone web front end for the Foundry agent built in [docs/03d](../docs/03d-foundry-agent-setup.md), in **On-Behalf-Of (OBO)** mode.

> **This is not a fork.** No application source is vendored here. This folder holds only the configuration deltas needed to point the upstream starter at this pattern's agent: an environment template, a deploy helper, and a `.gitignore`. The full step-by-step is in **[docs/09-foundry-agent-webapp.md](../docs/09-foundry-agent-webapp.md)**; the upstream README is the source of truth for the app itself.

## Why OBO

This pattern's agent connects a **Microsoft Fabric data agent** tool, which requires the **signed-in user's identity** to pass through (service-principal / managed-identity auth is not supported). The web app's default **MI mode** cannot satisfy that; its opt-in **OBO mode** can. See [docs/08](../docs/08-rbac-and-identity-passthrough.md) for the identity model.

## Files

| File | Purpose |
|---|---|
| [`.env.example`](./.env.example) | Template for the agent identifiers + the OBO flag. Copy to `.env` and fill in. |
| [`deploy-webapp.ps1`](./deploy-webapp.ps1) | Helper that reads `.env`, applies the values via `azd env set` (including OBO), and runs `azd up`. |
| [`.gitignore`](./.gitignore) | Excludes the populated `.env` and `azd` state. The upstream app is scaffolded **outside** this repo (not vendored), so it never needs ignoring here. |

## Quick start

```pwsh
# 1. Fill in your agent identifiers (this file stays in the repo, gitignored)
Copy-Item webapp/.env.example webapp/.env
#   edit webapp/.env

# 2. Initialize the upstream starter OUTSIDE this repo (per docs/09 § W2) so it is
#    never committed here. Run from the PARENT folder of this repo:
mkdir foundry-agent-webapp; cd foundry-agent-webapp
azd init -t microsoft-foundry/foundry-agent-webapp

# 3. From that app directory, deploy in OBO mode using the helper
#    (it reads this repo's webapp/.env and runs `azd up`).
pwsh <path-to-this-repo>/webapp/deploy-webapp.ps1
```

Full prerequisites, RBAC, validation, and caveats: **[docs/09-foundry-agent-webapp.md](../docs/09-foundry-agent-webapp.md)**.

## 100% synthetic / no real data

Keep real tenant identifiers, subscription IDs, and endpoints in your **local** `webapp/.env` only — never commit them. `.env.example` ships with placeholders only.
