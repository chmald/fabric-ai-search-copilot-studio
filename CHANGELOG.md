# Changelog — RAG Knowledge-Base Pattern

Decision and change history for this pattern. Internal-only — this file is marked `export-ignore` in `.gitattributes` so it does **not** ship to the public GitHub mirror (see `scripts/publish-to-github.ps1`).

Entries are listed newest-first.

---

## 2026-05-26

### Deployer Key Vault Secrets Officer grant added to Bicep
`infra/modules/rbac.bicep` now grants `deployerPrincipalId` the **Key Vault Secrets Officer** role on the Key Vault (gated by the same `!empty(deployerPrincipalId)` check as the Search role grants). Without this, the operator hits `403 Forbidden` on `az keyvault secret set` when storing the DI-caller SP secret in [docs/03b-fabric-setup.md § F2.2 step 3](./docs/03b-fabric-setup.md). The manual path in [docs/03-deployment-manual.md §§ 1.2 and 1.7](./docs/03-deployment-manual.md) now includes the explicit `az role assignment create` command for the same grant.

### Soft-delete restore for Foundry resource (opt-in pattern)
Added an opt-in `restoreFoundryFromSoftDelete` Bicep parameter (default `false`) and a matching `-RestoreFoundry` switch on `infra/deploy.ps1`. When the param is `true`, `infra/modules/aifoundry.bicep` adds `properties.restore: true` to the Foundry account via `union()`; otherwise the property is omitted. Rationale: an always-on `restore: true` was tried first but rejected by the Cognitive Services ARM provider on fresh creates with `CanNotRestoreANonExistingResource: Could not locate a resource to restore`. The opt-in pattern is the correct stable shape — fresh deploys are unaffected, and operators recover from `FlagMustBeSetForRestore` by re-running `pwsh ./infra/deploy.ps1 -RestoreFoundry`. Preserving the MI matters because the DI-caller SP's `Cognitive Services User` role assignment on the Foundry resource is granted manually (per [docs/03b-fabric-setup.md § F2.2 step 2](./docs/03b-fabric-setup.md)) and would be orphaned by any purge-and-recreate cycle. See [docs/06-troubleshooting.md § 0.5](./docs/06-troubleshooting.md#05-bicep-deploy-fails-flagmustbesetforrestore-soft-deleted-foundry--cognitive-services-account).

### Chat completion deployment made opt-in
Changed `chatModelName` default from `gpt-4o` to `''` in `infra/main.bicep` and `main.parameters.json`. The `chatDeployment` resource in `modules/aifoundry.bicep` is now wrapped in `if (!empty(chatModelName))`. Rationale: an audit found that no code path in the locked design consumes the chat completion model — `scripts/post_deploy_search.py` only references the embedding deployment, the Fabric OCR notebook only calls Document Intelligence, AI Search vectorizer/skillset only embed, and Copilot Studio's generative answers run on its own host model (the M365 Copilot model). The `gpt-4o` deployment was provisioned just-in-case and consumed 10K TPM of subscription quota for no benefit. Opt in by setting `chatModelName` to `gpt-4o` (or `gpt-4o-mini`) when an engagement explicitly needs a chat endpoint (custom app code, Foundry agent runtime, Copilot Studio bring-your-own-model). The `deploymentSummary` Bicep output now also emits a `chatDeployed: bool` flag so tooling can branch on it.

## 2026-05-25

### AI Search Bicep auth fix
Removed the `authOptions: { aadOrApiKey: ... }` block from `modules/search.bicep` — the Azure Search API treats `authOptions` and `disableLocalAuth: true` as mutually exclusive (`BadRequest: AuthOptions must be null if DisableLocalAuth is true`). Bearer challenges still work by default when local auth is disabled. See [docs/06-troubleshooting.md § 0.4](./docs/06-troubleshooting.md#04-bicep-deploy-fails-authoptions-must-be-null-if-disablelocalauth-is-true).

### Document Intelligence consolidated into the Azure AI Foundry resource
Removed the standalone `Microsoft.CognitiveServices/accounts` of `kind=FormRecognizer` (and its `modules/docintelligence.bicep` module + its dedicated managed identity + duplicate Storage Blob Data Reader role assignment). DI is now served by the Foundry account (`kind=AIServices` is a multi-service Cognitive Services account). Net result: 4 Azure resources instead of 5, single MI for both OpenAI and DI storage access, single RBAC surface. See [docs/01-architecture.md § 8](./docs/01-architecture.md#8-document-intelligence-prebuilt-read-served-by-the-foundry-resource) for the design rationale.

## 2026-05-22

### Artifact restructure
`docs/` folder layout, Bicep IaC + 5 modules, dual deployment path (manual + automated), ADO pipeline.

## 2026-05-21

### Locked architecture decisions
Copilot Studio orchestration for knowledge-base Q&A, Foundry as model gateway, integrated vectorizer, hybrid + semantic ranker, OneLake + Blob storage, Fabric Data Pipelines.
