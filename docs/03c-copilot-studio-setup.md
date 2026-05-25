# 03c — Copilot Studio agent setup (manual — both deployment paths)

The Copilot Studio layer of this pattern is **always manual**. Copilot Studio is a Power Platform service, not Azure — there is no Bicep / ARM / Terraform surface for agent definitions, knowledge sources, or channel publishing. Both the [manual Azure deployment](./03-deployment-manual.md) and the [Bicep-automated deployment](./04-deployment-automated.md) end at the same point: an AI Search index ready to be consumed by a Copilot Studio agent built with the steps in this document.

> **Run this doc last.** You need the Azure platform layer ([03-deployment-manual.md](./03-deployment-manual.md) **or** [04-deployment-automated.md](./04-deployment-automated.md)) and the Fabric ingest pipeline ([03b-fabric-setup.md](./03b-fabric-setup.md)) complete first, with at least one batch of chunks already in the AI Search index. Without indexed content the agent will return "I don't have enough information" to every question.

> **Time budget.** First-time build: **30–45 minutes** of hands-on time, plus **1–2 business days** of waiting for Teams / M365 Copilot publishing approvals if your tenant hasn't already cleared them. Subsequent rebuilds in the same Power Platform environment: **15 minutes**.

---

## What you'll build

```
Power Platform environment (default or named)
└── Copilot Studio agent: agent-rag-kb
    ├── Instructions / system prompt
    ├── Knowledge sources
    │     └── Azure AI Search → idx-rag-documents
    │         (Entra ID auth → caller's identity OR stored SP connection)
    ├── Generative answers: ON (knowledge source bound)
    └── Published channels
        ├── Microsoft Teams
        └── Microsoft 365 Copilot
```

The agent uses **Copilot Studio's native AI Search knowledge source** for retrieval — Copilot Studio's runtime handles query rewriting, retrieval, ranking, generative answering, and citation rendering. No Foundry agent runtime, no custom orchestrator, no application code is required.

---

## Phase C0 — Tenant & licensing prerequisites

Before you can build the agent, confirm the following with your Power Platform / M365 admin. None of these are owned by the builder; if any are missing you'll be blocked at agent creation or channel publishing.

### C0.1 Builder licensing

| Requirement | Required state | Why |
|---|---|---|
| **Copilot Studio license** for the building user | Maker access (typically via a **Microsoft Copilot Studio User** or **Microsoft 365 Copilot** license SKU) | Lets you create agents |
| **Power Platform environment** | Named environment with at least **Maker** role for the builder | Default environment works for demo, but a named per-project environment is recommended for production |
| **Dataverse provisioned** in the environment | Yes (auto-provisioned in Copilot Studio agent creation) | Stores agent state, knowledge bindings, conversation history |

Reference: [Copilot Studio licensing](https://learn.microsoft.com/microsoft-copilot-studio/requirements-licensing-subscriptions).

### C0.2 Channel publishing approvals

Both Teams and M365 Copilot publishing routes require **tenant-admin approval the first time** an agent is published. Initiate the approvals **before** you start the build — they take 1–2 business days.

| Channel | Admin action | Reference |
|---|---|---|
| **Microsoft Teams** | M365 admin enables **Power Platform / Copilot Studio agent submission** in the Teams admin center | [Add the agent to Teams](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams) |
| **Microsoft 365 Copilot** | M365 admin enables agents in the **M365 admin center → Integrated apps → Copilot agents** view; agent appears in the M365 Copilot agent gallery only after the agent is published + approved | [Publish to Microsoft 365 Copilot](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-copilot) |

For demo builds with a small audience you can use the **Test pane only** path and skip channel publishing entirely.

### C0.3 AI Search access pattern

The agent's AI Search knowledge source authenticates with **Entra ID** (admin / query keys are disabled on the AI Search service from Phase 1.6 of the manual deploy or the equivalent Bicep). Two patterns are supported:

| Pattern | Use when | What to set up |
|---|---|---|
| **Caller's identity** (interactive) | Demo with a small audience; pilot phase; every user has a direct Entra account | Grant each user (or a security group) **Search Index Data Reader** on the AI Search service |
| **Stored service-principal connection** | Broad / production deployment; users may not have direct AI Search RBAC | Create a service principal, grant it **Search Index Data Reader** on the search service, store its credentials in a **Power Platform connection reference** or a **custom connector** |

The "Caller's identity" path is the default and works out of the box for demo. Switch to the SP path when you go to production. Reference: [Connect to Azure AI Search](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-azure-ai-search).

---

## Phase C1 — Create the agent

1. Open **[Copilot Studio](https://copilotstudio.microsoft.com/)**
2. Confirm the **environment selector** (top right) shows the environment you want the agent in. Switch if needed.
3. **Create → New agent** (or **Agents → + New agent**)
4. **Name:** `agent-rag-kb` (or your customer-friendly name — this is what users see in Teams / M365 Copilot)
5. **Description:** "Knowledge assistant for `<customer / corpus name>`. Answers questions grounded on internal documents with citations."
6. **Instructions / system prompt** — paste the starter below and tailor:

   > You are a knowledge assistant grounded on the customer's document corpus.
   > Answer concisely and cite the source document for every factual claim.
   > If the knowledge source does not contain enough information to answer
   > confidently, say so and offer to escalate to a human.
   > Do not invent facts. Do not answer questions outside the corpus.

7. **Create**

The agent opens to its **Overview** tab. Record the agent's display name and the environment GUID in `demo-ids.local.json` under `copilotStudio.agentName` / `copilotStudio.environmentId`.

> **Why "agent" not "copilot"?** Microsoft has unified the term: what used to be called "Copilot Studio copilots" are now called "agents." The product UI uses both interchangeably in transition; in this doc we use **agent** to align with the current Microsoft Learn vocabulary.

---

## Phase C2 — Bind the AI Search knowledge source

### C2.1 Add the knowledge source

1. In the agent: **Knowledge** (left nav) → **+ Add knowledge**
2. Choose **Azure AI Search**
3. **Connection / Authentication kind:**
   - **For demo (caller's identity):** select your own Microsoft Entra account from the **Authenticate as** dropdown. The first time you bind, Copilot Studio prompts for consent — accept.
   - **For production (service principal):** click **+ New connection** → select a **stored Azure AI Search connection** that references the SP, or create one in **Power Apps → Connections → + New connection → Azure AI Search**. Enter the SP's tenant ID, client ID, and client secret (stored in Power Platform's secret vault, not in plain text).
4. **Search endpoint:** `https://srch-rag-<env>-<region>.search.windows.net` (look up exact name in `demo-ids.local.json`)
5. **Index name:** `idx-rag-documents`
6. **Continue**

### C2.2 Map the schema fields

Copilot Studio uses the schema mapping to render citations and to decide which fields to feed the generative model.

| Copilot Studio field | Value | Why |
|---|---|---|
| **Title field** | `doc_id` | Shown as the citation heading in answers |
| **URL field** | `source_uri` | Makes citations clickable; opens the original blob in a new tab |
| **Content field** | `content` | The text the LLM grounds answers on |
| **Enable semantic search** | **ON** ← critical | Without this, the agent uses keyword-only search and quality drops sharply |

> If a friendlier title is wanted (e.g. the original filename instead of the `file_id` GUID), add a `title` string field to the index in [03-deployment-manual.md § 4.1](./03-deployment-manual.md#41-create-the-index) (and populate it from `source_path` in `nb_ocr_chunk_upload`'s chunk payload) and select it here instead of `doc_id`.

### C2.3 Save and validate

1. **Save**
2. Wait ~30 seconds for the knowledge source to show **Status: Ready**
3. If the status sticks on **Validating** or shows an auth error:
   - For caller's-identity auth — confirm your account has **Search Index Data Reader** on the search service
   - For SP auth — confirm the SP has **Search Index Data Reader** on the search service
   - Check role propagation (up to 15 minutes), then refresh the knowledge sources list

---

## Phase C3 — Configure generative answers

By default, Copilot Studio agents can fall back to their underlying LLM ("open-domain" answers) when the knowledge source doesn't contain the answer. For a grounded RAG agent we want the knowledge source to be the **only** source.

1. **Generative AI** (left nav) → **Settings**
2. **Knowledge source** → select the AI Search source from C2 (it's the only one if you haven't added others)
3. **Generative answers** → **Enabled**
4. **Use general knowledge** → **Off** (forces the agent to answer only from the AI Search index — best for a citation-required corpus)
5. **Content moderation** → leave at **High** unless you have a specific reason to lower it
6. **Save**

Reference: [Configure generative answers](https://learn.microsoft.com/microsoft-copilot-studio/nlu-generative-answers).

---

## Phase C4 — Test in the agent canvas

Use the **Test** pane (right side of the agent designer) to validate quality before publishing.

Run at least four categories of questions per [05-testing.md § E](./05-testing.md):

| Category | Example | Expected behavior |
|---|---|---|
| **Factual single-doc** | "What is the policy on remote work?" | Direct answer + 1 citation to the relevant doc |
| **Semantic / paraphrased** | "Can employees work from home?" | Same answer as above (semantic ranker matched paraphrase) |
| **Multi-doc** | "What does the handbook say about both remote work and travel?" | Answer with 2+ citations across docs |
| **Out-of-corpus** | "What is the capital of France?" | "I don't have information on that in the knowledge source" (because **Use general knowledge** is off) |

For each answer, confirm:

- [ ] Citation appears as a footnote / numbered reference below the answer
- [ ] Clicking the citation opens the source blob URL (or surfaces the blob URI for the user)
- [ ] Answer length is reasonable (not a one-word reply, not a 20-paragraph dump)
- [ ] No hallucinated facts — every claim traces back to a citation

If quality is poor, iterate on:

1. The system prompt (Phase C1 step 6) — make grounding requirements more explicit
2. The chunking strategy in `nb_ocr_chunk_upload` ([03b § F7.2](./03b-fabric-setup.md#f72-nb_ocr_chunk_upload)) — change `CHUNK_TOKENS` / `OVERLAP_TOKENS`
3. The AI Search semantic configuration ([03-deployment-manual.md § 4.1](./03-deployment-manual.md#41-create-the-index)) — adjust `prioritizedContentFields` / `prioritizedKeywordsFields`

---

## Phase C5 — Publish to channels

### C5.1 Microsoft Teams

1. **Channels** (left nav) → **Microsoft Teams** → **Turn on Teams**
2. The first time, Copilot Studio prompts for tenant approval. Click **Submit for admin approval** (or **Publish** if approval is already in place from C0.2).
3. Once approved, open the published agent link → installs the agent into Teams
4. Pin the agent for easier access

Reference: [Add your agent to Microsoft Teams](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams).

### C5.2 Microsoft 365 Copilot

1. **Channels** (left nav) → **Microsoft 365 Copilot** → **Turn on Microsoft 365 Copilot**
2. **Submit for admin approval** if not already cleared
3. Once approved, the agent appears in the **Microsoft 365 Copilot agent gallery** for users with M365 Copilot licenses (in Word, Outlook, Teams, copilot.microsoft.com, etc.)

Reference: [Publish your agent to Microsoft 365 Copilot](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-copilot).

### C5.3 Other channels (optional)

Copilot Studio supports many other channels (web chat, Slack, Facebook, custom apps, Direct Line). For this pattern, Teams + M365 Copilot are the canonical demo / production targets. Add others as needed via **Channels → + Add channel**.

---

## Phase C6 — Validate end-to-end

After publishing, validate from the user side — not from the Test pane.

- [ ] Open Teams as a normal user (not the builder)
- [ ] Find the agent in the Teams app catalogue → install
- [ ] Ask a representative question from your golden set ([05-testing.md § C](./05-testing.md))
- [ ] Confirm answer + citation render correctly
- [ ] Click the citation → confirm it opens the original document in Blob (may require the user to have **Storage Blob Data Reader** on the storage account, or a SAS-token rewrite layer if the source blobs are private)
- [ ] Repeat from the M365 Copilot agent gallery in a host app (Word or Outlook)

If a user can't see the agent in Teams / M365 Copilot:

- They may not have a Copilot Studio user license / M365 Copilot license — check the **Licenses** view in M365 admin center
- The admin approval may not have propagated yet — typical wait 1–2 hours after admin approves
- The user may be in a different Power Platform environment — confirm the agent's environment matches the user's default

---

## Phase C6 validation checklist

- [ ] Agent created in the expected Power Platform environment
- [ ] AI Search knowledge source bound and showing **Status: Ready**
- [ ] **Enable semantic search** is **ON** in the knowledge source
- [ ] **Use general knowledge** is **OFF** in generative answers settings (for strict grounding)
- [ ] Test pane returns grounded answers with citations on all four question categories
- [ ] Teams channel published; agent reachable in a Teams chat as a normal user
- [ ] M365 Copilot channel published; agent reachable in the M365 Copilot agent gallery
- [ ] End-to-end: question in Teams → answer with clickable citation → opens raw file in Blob

When all boxes are checked → proceed to [05-testing.md](./05-testing.md) for the formal retrieval-quality evaluation (golden set, semantic-ranker A/B, demo script rehearsal).

---

## Troubleshooting pointers

Common Copilot Studio-layer issues:

| Symptom | Likely cause | Fix |
|---|---|---|
| Knowledge source stuck on **Validating** | Caller / SP missing **Search Index Data Reader** on the AI Search service | Grant the role; wait 15 min for propagation |
| Knowledge source shows auth error | Local-key auth attempted but disabled on AI Search | Re-bind with Entra auth (caller's identity or SP), not admin/query key |
| Test pane returns "I don't have information" for every question | Index is empty, or **Enable semantic search** is off, or `content` field mapping is wrong | Check index doc count (Phase 4 validation), re-check schema mapping in C2.2 |
| Citations missing or unclickable | `URL field` not mapped, or `source_uri` field is null in indexed chunks | Re-check field mapping in C2.2; verify `nb_ocr_chunk_upload` is populating `source_uri` in chunk JSON |
| Agent gives answers but no citations | Generative answers configured but knowledge source isn't the bound source | Re-check C3 step 2 — knowledge source must be selected |
| Hallucinated answers (no citation, off-topic) | **Use general knowledge** is on | Turn it off in C3 step 4 |
| Teams publish stuck on **Pending admin approval** | M365 admin hasn't cleared the submission | Follow up with M365 admin; typical SLA 1–2 business days |
| User in Teams sees "Agent not available" | User not licensed, or in a different Power Platform environment, or admin approval hasn't propagated | Check licensing + environment + approval status |

For the AI Search-side issues (indexer failures, vectorizer auth, blob 403s), see [06-troubleshooting.md § 4](./06-troubleshooting.md#4--ai-search-index--indexer).

---

## Reference documentation

- [Copilot Studio overview](https://learn.microsoft.com/microsoft-copilot-studio/fundamentals-what-is-copilot-studio)
- [Copilot Studio licensing](https://learn.microsoft.com/microsoft-copilot-studio/requirements-licensing-subscriptions)
- [Connect to Azure AI Search as a knowledge source](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-add-azure-ai-search)
- [Configure generative answers](https://learn.microsoft.com/microsoft-copilot-studio/nlu-generative-answers)
- [Add your agent to Microsoft Teams](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams)
- [Publish your agent to Microsoft 365 Copilot](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-copilot)
- [Power Platform environments overview](https://learn.microsoft.com/power-platform/admin/environments-overview)
- [Microsoft 365 Copilot agent gallery](https://learn.microsoft.com/microsoft-365-copilot/agents/agents-overview)

---

*Last updated: 2026-05-24*
