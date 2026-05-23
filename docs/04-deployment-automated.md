# 04 — Deployment (Automated / Bicep + scripts)

The automated deployment path. Provisions the Azure platform layer via Bicep, then configures the AI Search index/datasource/indexer via a post-deploy Python script (because AI Search index / indexer resources are not cleanly expressible in Bicep / ARM today).

> **Two paths exist; this is the automated one.** For the manual portal / CLI walkthrough, see [03-deployment-manual.md](./03-deployment-manual.md). The two paths produce the same end-state.

> **What this path DOES NOT cover.** Fabric workspace creation and Copilot Studio agent configuration are not in Bicep — they are portal-driven low-code components. The full Fabric build (workspace, identity, Lakehouse, OneLake shortcut, control table, connections, pipeline) is in its own dedicated document: **[03b-fabric-setup.md](./03b-fabric-setup.md)**. The Copilot Studio agent build is in [00-reproduce-this-demo.md § Part D](./00-reproduce-this-demo.md#part-d--build-the-copilot-studio-agent-manual--both-paths). Both are identical regardless of which Azure path (manual or this one) you took.

---

## What gets deployed

| Resource | Bicep module | What it does |
|---|---|---|
| Resource group | `main.bicep` (subscription scope) | Container for everything else |
| Key Vault | `modules/keyvault.bicep` | RBAC-mode; for any non-managed-identity secrets |
| Storage account + `raw/` + `chunks/` containers | `modules/storage.bicep` | Permanent canonical store |
| Document Intelligence | `modules/docintelligence.bicep` | `prebuilt-read` OCR (Standard S0) |
| Azure AI Foundry resource | `modules/aifoundry.bicep` | Model gateway hosting `text-embedding-3-large` + `gpt-4o` |
| AI Search Standard S1 | `modules/search.bicep` | Hybrid + semantic ranker enabled, system-assigned MI |
| RBAC role assignments | `modules/rbac.bicep` | Search MI → `Cognitive Services OpenAI User` on Foundry; Search MI → `Storage Blob Data Reader` on Storage |

**What is NOT deployed by Bicep** (configured by the post-deploy script):

- AI Search index `idx-rag-documents` (vector + hybrid + semantic configuration)
- AI Search data source `ds-chunks` (managed-identity connection to Blob)
- AI Search indexer `ixr-chunks` (with integrated AOAI vectorizer)

**What is NOT deployed by either** (manual portal steps):

- **Fabric workspace + Lakehouse + OneLake shortcut + control table + connections + Data Pipeline** — see [03b-fabric-setup.md](./03b-fabric-setup.md) (always manual)
- **Copilot Studio agent + knowledge source binding + channel publishing** — see [00-reproduce-this-demo.md § Part D](./00-reproduce-this-demo.md#part-d--build-the-copilot-studio-agent-manual--both-paths)

---

## Prerequisites

- All boxes in [02-prerequisites.md § Pre-flight checklist](./02-prerequisites.md#15--pre-flight-checklist) confirmed
- Azure CLI 2.60+ with Bicep extension: `az bicep install && az bicep upgrade`
- PowerShell 7+ (`pwsh`)
- Python 3.11+ with `pip`
- `az login` succeeded with an identity that has **Contributor + User Access Administrator** at the **subscription** scope (the deployment targets subscription scope and creates the RG)

---

## Step 1 — Configure parameters

Copy the parameter template and fill in your values:

```pwsh
cd <repo-root>
Copy-Item infra/main.parameters.json infra/main.parameters.local.json
# edit infra/main.parameters.local.json
```

Minimum values to set:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location":          { "value": "eastus2" },
    "workloadName":      { "value": "rag" },
    "env":               { "value": "dev" },
    "embeddingModelName":{ "value": "text-embedding-3-large" },
    "embeddingModelTpm": { "value": 10 },
    "chatModelName":     { "value": "gpt-4o" },
    "chatModelTpm":      { "value": 10 }
  }
}
```

`*.local.json` is `.gitignored` — your local parameter file with real values never ends up in the repo.

---

## Step 2 — Dry-run (what-if)

Always run a `what-if` first to confirm what will be created:

```pwsh
az deployment sub what-if `
  --location eastus2 `
  --template-file infra/main.bicep `
  --parameters infra/main.parameters.local.json
```

Review the output. It should show: 1 RG creation + 6 module deployments (Key Vault, Storage, Foundry, model deployments, Doc Intelligence, AI Search, RBAC).

---

## Step 3 — Deploy

Either invoke the wrapper:

```pwsh
pwsh ./infra/deploy.ps1 `
  -ParameterFile infra/main.parameters.local.json `
  -DeploymentName rag-kb-bicep-$(Get-Date -Format yyyyMMdd-HHmm)
```

Or run `az` directly:

```pwsh
az deployment sub create `
  --name rag-kb-bicep-$(Get-Date -Format yyyyMMdd-HHmm) `
  --location eastus2 `
  --template-file infra/main.bicep `
  --parameters infra/main.parameters.local.json
```

Typical runtime: **8–15 minutes** dominated by AI Search service provisioning and AOAI model deployment propagation.

After the deployment completes, capture the outputs to your local IDs file:

```pwsh
az deployment sub show `
  --name rag-kb-bicep-<your-deployment-name> `
  --query "properties.outputs.deploymentSummary.value" `
  -o json > demo-ids.local.json
```

> ⚠️ `demo-ids.local.json` is `.gitignored`. Never commit a populated `demo-ids.json`. See `demo-ids.template.json` for the schema.

---

## Step 4 — Configure AI Search (post-deploy script)

Bicep deployed the AI Search **service**. The script below creates the **index** (with integrated AOAI vectorizer + semantic configuration), the **data source** (managed-identity connection to Blob), and the **indexer**.

```pwsh
cd scripts
pip install -r requirements.txt
python post_deploy_search.py --ids ../demo-ids.local.json
```

The script reads the deployment outputs from `demo-ids.local.json` and issues REST calls against the AI Search service. It is **idempotent** — safe to re-run if the first attempt fails partway. Typical runtime: **30–60 seconds**.

Expected output:

```
[OK] Index 'idx-rag-documents' created (or already exists, updated)
[OK] Data source 'ds-chunks' created (managed-identity connection to stragdeveastus2/chunks)
[OK] Indexer 'ixr-chunks' created (schedule: PT5M)
[OK] Manual indexer run triggered; status will be 'success' once the first sample chunk is in the blob container
```

---

## Step 5 — Verify

Run the smoke tests:

```pwsh
python scripts/post_deploy_search.py --ids demo-ids.local.json --verify
```

This:

1. Hits the search index `$count` endpoint — confirms the index exists and is reachable
2. Runs a semantic-typed test query — confirms the integrated vectorizer + semantic ranker fired
3. Reports indexer status — confirms the data source is wired correctly

Expected:

```
[OK] Index exists. Document count: 0  (will populate after Fabric pipeline writes chunks)
[OK] Sample query succeeded. Semantic ranker score range: empty (0 docs — re-test after first ingest)
[OK] Indexer 'ixr-chunks' status: success  (or transientFailure on first run with empty container — normal)
```

If any check fails, see [06-troubleshooting.md § 4](./06-troubleshooting.md) for the AI Search-specific diagnosis flow.

---

## Step 6 — Finish the manual steps

Bicep + script have provisioned the entire Azure platform layer. Now finish:

- **Fabric setup** — [03b-fabric-setup.md](./03b-fabric-setup.md) (workspace, identity, Lakehouse, OneLake shortcut, control table, connections, ingest pipeline)
- **Part D** in [00-reproduce-this-demo.md](./00-reproduce-this-demo.md) — Copilot Studio agent build + channel publish

Once both are complete, jump to [05-testing.md](./05-testing.md).

---

## Tearing down

To remove everything Bicep created:

```pwsh
az group delete --name $(az deployment sub show --name <your-deployment> --query "properties.outputs.deploymentSummary.value.resourceGroup" -o tsv) --yes
```

Or just delete the resource group from the portal. Fabric workspace and Copilot Studio agent must be deleted separately from their respective portals.

---

## CI/CD with Azure DevOps

The `.azuredevops/pipelines/deploy-rag-kb.yml` pipeline implements:

1. **Validate** stage — `az bicep build` + `az deployment sub what-if` + Python lint + tests
2. **Deploy** stage — `az deployment sub create` + `python post_deploy_search.py` + verify
3. **Smoke** stage (optional) — runs a sample query against the new index

Per-environment values come from ADO **variable groups**: `rag-kb-env-dev` and `rag-kb-env-prod`. The pipeline reads from `$(Build.SourceBranchName)` to pick the correct group.

See [00-reproduce-this-demo.md § Part F](./00-reproduce-this-demo.md) for ADO wire-up.

---

## Comparison: when to use which path

| Scenario | Recommended path |
|---|---|
| First time touching this pattern | Manual ([03-deployment-manual.md](./03-deployment-manual.md)) — better learning |
| Customer demo / one-off lab | Manual — easier to talk through component-by-component |
| Stand up dev + prod environments | Automated — Bicep is faster + ensures parity |
| Customer wants the IaC | Automated — hand them the Bicep + ADO pipeline |
| CI-driven deployments | Automated only |
| Tearing down / rebuilding repeatedly | Automated — `az group delete` + re-run |

---

*Last updated: 2026-05-22*
