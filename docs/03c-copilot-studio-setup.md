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
    │         (Power Platform data connection → Entra ID Integrated
    │          OR Service principal — NEVER Access Key)
    ├── Grounding settings
    │     ├── Allow the AI to use its own general knowledge: OFF
    │     └── Allow ungrounded responses: OFF
    └── Channels
        └── Teams and Microsoft 365 Copilot   (single combined channel;
                                             toggle inside controls
                                             M365 Copilot vs Teams-only)
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

This pattern uses Copilot Studio's combined **Teams and Microsoft 365 Copilot** channel — a single channel surface that publishes the agent to both Microsoft Teams and the Microsoft 365 Copilot agent gallery (with an in-channel toggle to opt out of M365 Copilot if you want Teams only).

Distributing to the whole organization requires **admin approval the first time** — plan ahead because it can take 1–2 business days for an admin to review and approve. Initiate the approvals before you start the build.

| Distribution option | Admin approval | Where it appears | When to use |
|---|---|---|---|
| **Just you** | Not required | Personal agent list in Teams + Microsoft 365 Copilot | Demo / pilot for the builder only |
| **Show to my teammates and shared users** | Not required (but you must explicitly share the agent with the users / security groups) | **Built with Power Platform** section of the Teams app store + the user's Microsoft 365 Copilot agent list | Small audience demo |
| **Show to everyone in my org** | **Required** — admin reviews in Microsoft 365 admin center, then approves in the Teams admin center's [Manage apps](https://learn.microsoft.com/microsoftteams/submit-approve-custom-apps) page | **Built for your org** section of the Teams app store + the Microsoft 365 Copilot **Built by your org** agent store section | Production rollout |

In addition to the per-agent approval, your tenant must already allow Power Platform apps in the Teams admin center ([Manage Power Platform apps in Teams](https://learn.microsoft.com/microsoftteams/manage-power-platform-apps)). Confirm with your admin if you're not sure.

Reference: [Connect and configure an agent for Teams and Microsoft 365](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams), [Publish agents for Microsoft 365 Copilot](https://learn.microsoft.com/microsoft-365/copilot/extensibility/publish).

For demo builds with a small audience you can use the **Test pane only** path and skip channel publishing entirely.

### C0.3 AI Search access pattern

The agent's AI Search knowledge source authenticates via a Copilot Studio **data connection** (Power Platform connection) — you cannot point Copilot Studio at the AI Search endpoint directly without a connection.

Because admin / query keys are disabled on the AI Search service in this pattern (from Phase 1.6 of the manual deploy or the equivalent Bicep), the connection **must use one of the Microsoft Entra ID auth types**, not an access key:

| Connection auth type (verbatim from the Copilot Studio UI) | Use when | What to set up |
|---|---|---|
| **Microsoft Entra ID Integrated** | Demo with a small audience; pilot phase; every user has a direct Entra account and is willing to consent on first use | Grant each user (or a security group) **Search Index Data Reader** on the AI Search service. The connection resolves to the calling user's identity at runtime. |
| **Service principal (Microsoft Entra ID application)** | Broad / production deployment; users may not have direct AI Search RBAC; you want all users to resolve to one stable identity | Create a service principal, grant it **Search Index Data Reader** on the search service. The connection stores the SP's tenant ID, client ID, and client secret (in Power Platform's secret vault). |
| ~~Access Key~~ | Never (in this pattern) | Disabled on the AI Search service. Selecting this fails. |
| ~~Client Certificate Auth~~ | Out of scope for this pattern | — |

Reference: [Add Azure AI Search as a knowledge source](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-azure-ai-search).

> **Document-level security trimming.** Because **Microsoft Entra ID Integrated** resolves to the calling user's identity, the user's token reaches AI Search — the prerequisite for chunk-level access control (see [01-architecture.md § Document-level access control](01-architecture.md#document-level-chunk-level-access-control)). Service-level access comes from the **Search Index Data Reader** grant above. Document-level trimming then comes from the `group_ids` security filter (GA) populated at chunk creation in [03b](03b-fabric-setup.md), validated in [05-testing.md § G](05-testing.md). **Nuance:** the GA security-filter approach needs the orchestration layer to inject a per-user `$filter` on `group_ids`; native Copilot Studio knowledge-source filter injection is deployment-specific. The preview ACL/RBAC-scope and Purview-label approaches enforce automatically from the user token instead.

> **Connection lifecycle caveat.** Power Platform data connections live at the **environment** level — not per-agent. A misconfigured AI Search connection can break the AI Search add-knowledge dialog **for every agent in the environment** with no in-product way to delete it. Stick to the supported Entra auth types above. If you hit a broken-connection state, see [Troubleshooting pointers](#troubleshooting-pointers).

---

## Phase C1 — Create the agent

1. Open **[Copilot Studio](https://copilotstudio.microsoft.com/)**
2. Confirm the **environment selector** (top right) shows the environment you want the agent in. Switch if needed.
3. **Create → New agent** (or **Agents → + New agent**)
4. **Name:** `agent-rag-kb` (or your preferred name — this is what users see in Teams / M365 Copilot)
5. **Description:** "Knowledge assistant for `<corpus name>`. Answers questions grounded on internal documents with citations."
6. **Instructions / system prompt** — paste the starter below and tailor:

   > You are a knowledge assistant grounded on your document corpus.
   > Answer concisely and cite the source document for every factual claim.
   > If the knowledge source does not contain enough information to answer
   > confidently, say so and offer to escalate to a human.
   > Do not invent facts. Do not answer questions outside the corpus.

7. **Create**

The agent opens to its **Overview** tab. Record the agent's display name and the environment GUID in `demo-ids.local.json` under `copilotStudio.agentName` / `copilotStudio.environmentId`.

> **Terminology note.** Microsoft Copilot Studio (and Microsoft Learn) now uses **agent** consistently across the UI and docs — the legacy term *copilot* still appears in some older docs and SDK names, but everywhere it matters in the build (Channels page, Agents list, Microsoft 365 admin center → Agents) the surface is **agent**. This doc uses **agent** throughout.

---

## Phase C2 — Bind the AI Search knowledge source

### C2.1 Add the knowledge source

1. In the agent, open the **Overview** page (or the **Knowledge** page — either entry point works).
2. Select **Add knowledge**. The **Add knowledge** dialog opens.
3. In the dialog, select the **Featured** tab.
4. Select **Azure AI Search**.
5. Select **Create new connection**. The connection dialog opens.
6. **Authentication type:** select one of the Entra options from [C0.3](#c03-ai-search-access-pattern):
   - **Microsoft Entra ID Integrated** — then sign in with your Entra account when prompted. First time only, accept the consent prompt.
   - **Service principal (Microsoft Entra ID application)** — enter the SP's **Tenant ID**, **Client ID**, and **Client Secret** (these get stored encrypted in Power Platform).
7. Select **Create**. A green check mark confirms the connection is valid.
8. Select **Next**.
9. Enter the **Azure AI Search vector index** name: `idx-rag-documents`. Only one index can be added per knowledge source.
10. Provide a **Name** and **Description** for the knowledge source:
    - **Name:** `rag-knowledge-base` (or a friendly name)
    - **Description:** as detailed as possible — e.g. *"Internal document corpus including policies, handbooks, and standard operating procedures. Use for all factual questions about company practices."* The description is used by Copilot Studio's [generative orchestration](https://learn.microsoft.com/microsoft-copilot-studio/advanced-generative-actions) to decide when to call this source, so be specific.
11. Select **Add to agent**.

The knowledge source appears in the **Knowledge** table with **Status: In progress** while Copilot Studio indexes the vector index metadata. Status flips to **Ready** within ~30–60 seconds.

> **No field mapping.** Unlike some older RAG knowledge connectors, the current Azure AI Search integration does **not** ask you to map Title / URL / Content fields manually — it consumes the schema of the vector index directly. The next subsection covers the field conventions that drive citations and grounding.

### C2.2 Field conventions for citations and grounding

Copilot Studio derives behavior from your index schema:

| Behavior | How it's resolved |
|---|---|
| **Content** the LLM grounds answers on | All searchable text fields in the index — in this pattern, the `content` field on `idx-rag-documents` |
| **Vector field** used for embedding-based retrieval | Detected from the index's `vectorSearch` configuration — in this pattern, `content_vector` with the `aif-vectorizer` integrated AOAI vectorizer |
| **Semantic ranking** | Triggered automatically when the index has a semantic configuration (`semantic-default` in [03-deployment-manual.md § 4.1](./03-deployment-manual.md#41-create-the-index)) |
| **Citation URL** (clickable link shown next to each answer) | Copilot Studio looks for `metadata_storage_path` first; if not present, it uses **any field whose value is a complete URL**. In this pattern, the chunk JSON written by [`nb_ocr_chunk_upload`](./03b-fabric-setup.md#f72-nb_ocr_chunk_upload) populates `source_uri` with the raw blob URL, which satisfies this convention. |
| **Citation label** | Generated from the content of the cited chunk — there is no separate "Title field" picker in the current UI |

Reference: [Return citations](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-azure-ai-search#return-citations).

> **Adding a friendly title for citations.** If you prefer human-readable citation labels over auto-generated previews, add a `title` string field to the AI Search index and populate it from `source_path` (the original filename) in the chunk JSON. Add it to the index schema in [§ 4.1](./03-deployment-manual.md#41-create-the-index) and to the chunk-build code in [`nb_ocr_chunk_upload`](./03b-fabric-setup.md#f72-nb_ocr_chunk_upload). Copilot Studio will surface the value automatically once it's in the index.

### C2.3 Validate the connection

1. Wait ~30–60 seconds for the Knowledge source row to flip from **Status: In progress** to **Status: Ready**.
2. If the status sticks on **In progress** or shows an error:
   - For **Microsoft Entra ID Integrated** — confirm your account has **Search Index Data Reader** on the search service
   - For **Service principal** — confirm the SP has **Search Index Data Reader** on the search service
   - Check role propagation (up to 15 minutes), then refresh the Knowledge page
3. If the row reports an unrecoverable error, see [Troubleshooting pointers](#troubleshooting-pointers) (broken connections can persist at the environment level).

> **Heads-up — "Microsoft Entra ID Integrated" flows the end-user identity to AI Search.** If you pick this auth type, **every user who chats with the agent** must hold `Search Index Data Reader` on the search service — not just the builder. That is why the *very first* query you run as the builder may fail until you grant the role to your own account, and why other testers will see "I don't have any information" until they are granted the role too. This is by design, not a missing config. For anything beyond a small demo audience, switch the connection to **Service principal** (see [C0.3](#c03-ai-search-access-pattern)) so the SP holds the role once and end users need no direct search RBAC. Full FAQ in [06-troubleshooting.md § 5.8](./06-troubleshooting.md#58-agent-works-for-me-but-fails-for-other-users-or-i-had-to-add-search-index-data-reader-to-my-own-account).

### C2.4 (Optional) Virtual Network support

If the AI Search service is locked down with a [private endpoint](https://learn.microsoft.com/azure/search/search-security-overview), Copilot Studio can still connect via the Power Platform VNet integration. Configure VNet support for your Power Platform environment first ([Set up Virtual Network support](https://learn.microsoft.com/power-platform/admin/vnet-support-setup-configure)), then proceed with the C2.1 steps unchanged. Out of scope for the default demo build.

---

## Phase C3 — Configure grounding behavior

For a citation-required RAG agent, the goal is: **answer ONLY from the AI Search index, never from the model's general knowledge.** Two related settings together control this; both must be off.

### C3.1 Turn off the agent-level general-knowledge fallback

1. Open the agent's **Overview** page.
2. Scroll to the **Knowledge** section.
3. Find **Allow the AI to use its own general knowledge** — turn it **Off**.

   This stops the agent from using its underlying LLM knowledge (Bing search, model parametric knowledge) as a fallback when the AI Search index doesn't return a hit.

Reference: [Knowledge sources summary](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-copilot-studio).

### C3.2 Block ungrounded responses (generative orchestration)

1. Open **Settings → Generative AI** (left nav).
2. Confirm **Generative orchestration** is enabled (required for the next toggle to apply).
3. Scroll to the **Knowledge** section.
4. Find **Allow ungrounded responses** — turn it **Off**.

   With this off, the agent **blocks any response generated in a turn where it didn't actually call a knowledge source or tool**. If the model tries to answer from conversation history or parametric memory without retrieving a chunk, the response is blocked and the agent triggers its **Fallback** topic (typically responding with "I don't have information on that").

5. **Content moderation** — leave at **High** unless you have a specific reason to lower it.
6. **Save**.

> **Why both toggles matter.** The Overview-page "Allow the AI to use its own general knowledge" gates the AI's right to **consult** general knowledge at all. The Generative-AI-settings "Allow ungrounded responses" enforces the per-turn rule that the model must have called the knowledge source for that response. With both off, the agent is in strict-grounding mode. Note: even with both off, the model can still blend general knowledge into a response that *did* retrieve a chunk — these settings prevent ungrounded responses, not ungrounded *phrases*. For per-user audit-grade verification, validate citations in the [05-testing.md § D](./05-testing.md) golden set.

Reference: [Allow ungrounded responses](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-copilot-studio#allow-ungrounded-responses), [Orchestrate agent behavior with generative AI](https://learn.microsoft.com/microsoft-copilot-studio/advanced-generative-actions).

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

Copilot Studio now uses a **single combined channel** for Teams and Microsoft 365 Copilot. Publishing to one or both is a matter of toggles, not two separate channel additions.

### C5.1 Publish the agent

Before the channel can be added, the agent must be published at least once.

1. From the agent's **Overview** page, select **Publish** (top right).
2. Confirm the publish action. Typical publish time: **30–60 seconds**.
3. Wait for the **Published successfully** confirmation. You can republish at any time after future edits — republishing pushes updates to all installed instances.

### C5.2 Add the Teams and Microsoft 365 Copilot channel

1. From the agent's top menu bar, select **Channels**.
2. Select the **Teams and Microsoft 365 Copilot** tile. The configuration panel opens.
3. Under **Turn on Microsoft 365**, keep **Make agent available in Microsoft 365 Copilot** **selected** (the default). Clear it only if you want Teams-only.
4. Select **Edit details** to customize the agent's icon, color, short description, and developer / privacy / terms-of-use URLs (these appear in the Teams app store and the M365 Copilot agent gallery).
5. Select **Save** → back on the channel panel, select **Add channel**.

Reference: [Connect an agent to the Teams and Microsoft 365 Copilot channels](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams#connect-an-agent-to-the-teams-and-microsoft-365-copilot-channels).

### C5.3 Install for yourself (builder validation)

Before sharing, install the agent in your own Teams / M365 Copilot to confirm it works end-to-end as a normal user (not just in the Test pane).

1. In the Teams and Microsoft 365 Copilot channel panel, select **See agent in Teams**. The Teams app store install dialog opens.
2. Select **Add**. The agent appears in your Teams left nav and in your Microsoft 365 Copilot agent list (if M365 was enabled in C5.2 step 3).
3. Open a chat with the agent in Teams and ask a representative question from your golden set ([05-testing.md § C](./05-testing.md)). Confirm answer + citation.
4. In Microsoft 365 Copilot (Word, Outlook, Teams, or copilot.microsoft.com), type `@` and select the agent from the list. Ask the same question and confirm parity.

### C5.4 Share with others (optional)

There are three distribution levels per [C0.2](#c02-channel-publishing-approvals). Choose based on your audience:

1. In the Teams and Microsoft 365 Copilot channel panel, select **Availability options**.
2. Choose one of:
   - **Copy link** — shareable installation link for a small audience. Recipients still need agent access (use **Share** in the agent's main menu to grant security groups).
   - **Show to my teammates and shared users** — adds the agent to the **Built with Power Platform** section of the Teams app store; visible only to users / groups the agent is explicitly shared with. **No admin approval required.** Best for pilot phase.
   - **Show to everyone in my org** — submits to admin approval. Once approved, the agent appears in the **Built for your org** section of the Teams app store and the **Built by your org** section of the Microsoft 365 Copilot agent gallery. Best for production rollout.
3. If you selected **Show to everyone in my org**, follow the on-screen confirmation, then **Submit for admin approval**.
4. Admin reviews the request in [Microsoft 365 admin center → Agents → All agents → Requests](https://admin.microsoft.com/), and approves / rejects from there. SLA: typically 1–2 business days.
5. After approval, the channel panel status flips to **Approved**. New installs (and updates for existing installs) automatically pick up the published version.

Reference: [Show an agent in the Teams app store or in the Microsoft 365 Agent Store](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams#show-an-agent-in-the-teams-app-store-or-in-the-microsoft-365-agent-store), [Manage requested Copilot Studio agents](https://learn.microsoft.com/microsoft-365/copilot/agent-essentials/agent-lifecycle/agent-copilot-studio-requested).

### C5.5 Other channels (optional)

Copilot Studio supports many other channels (web chat, Slack, Facebook, custom apps, Direct Line). For this pattern, Teams + M365 Copilot are the canonical demo / production targets. Add others as needed via the **Channels** page.

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
- [ ] AI Search knowledge source bound via **Microsoft Entra ID Integrated** or **Service principal** (not Access Key) and showing **Status: Ready**
- [ ] Vector index name = `idx-rag-documents`; description is detailed (not just the index name)
- [ ] Overview-page **Allow the AI to use its own general knowledge** is **Off**
- [ ] Generative AI settings **Allow ungrounded responses** is **Off** (with generative orchestration enabled)
- [ ] Test pane returns grounded answers with citations on all four question categories
- [ ] Agent published at least once (required before adding the channel)
- [ ] **Teams and Microsoft 365 Copilot** channel added with **Make agent available in Microsoft 365 Copilot** selected
- [ ] Agent installed for the builder and reachable from both Teams and M365 Copilot
- [ ] For broader rollout: Availability options set to the appropriate scope (shared users or org-wide with admin approval)
- [ ] End-to-end: question in Teams → answer with clickable citation → opens raw file in Blob

When all boxes are checked → proceed to [05-testing.md](./05-testing.md) for the formal retrieval-quality evaluation (golden set, semantic-ranker A/B, demo script rehearsal).

---

## Troubleshooting pointers

Common Copilot Studio-layer issues:

| Symptom | Likely cause | Fix |
|---|---|---|
| Knowledge source stuck on **In progress** | Caller / SP missing **Search Index Data Reader** on the AI Search service | Grant the role; wait 15 min for propagation, then refresh the Knowledge page |
| Knowledge source shows auth error | Tried to use an Access Key against a search service with `disableLocalAuth=true` | Recreate the connection with **Microsoft Entra ID Integrated** or **Service principal**. See [C2.1](#c21-add-the-knowledge-source). |
| **Add knowledge** dialog briefly opens then errors out and is unusable for any agent | A previously created Azure AI Search connection in this Power Platform environment is broken; the broken connection lives at the environment scope and there is no in-product way to delete it | Reset the agent's external access, or delete and recreate the affected agent. When re-adding, use one of the **Entra ID** auth types, not **Access Key**. See [Add Azure AI Search as a knowledge source — Create the connection](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-azure-ai-search#create-the-connection-to-azure-ai-search). |
| Test pane returns "I don't have information" for every question | Index is empty, or the wrong vector index name was entered in C2.1 step 9, or the `content` field is empty in chunk JSONs | Check index doc count ([03-deployment-manual.md § 4](./03-deployment-manual.md#phase-4--ai-search-index) validation), re-check the index name in the Knowledge source configuration |
| Citations missing or unclickable | Indexed chunks have no field containing a complete URL (no `metadata_storage_path`, no other URL-valued field) | Verify `source_uri` in chunk JSON is populated with the full `https://<storage>.blob.core.windows.net/...` URL — see [`nb_ocr_chunk_upload`](./03b-fabric-setup.md#f72-nb_ocr_chunk_upload). Re-run the AI Search indexer if the field was added after first index. |
| Agent gives answers but no citations | Knowledge source isn't bound at the agent level (maybe only on a topic-level generative answers node) | Confirm the source appears in the agent's **Knowledge** page, not only inside a topic |
| Hallucinated answers (claims with no citation) | **Allow ungrounded responses** is still On, or **Allow the AI to use its own general knowledge** is still On | Turn both off per [C3.1](#c31-turn-off-the-agent-level-general-knowledge-fallback) and [C3.2](#c32-block-ungrounded-responses-generative-orchestration) |
| **Add channel** button greyed out | Agent has never been published | Publish the agent first ([C5.1](#c51-publish-the-agent)). The channel cannot be added until at least one publish has succeeded. |
| **Show to everyone in my org** stuck on **Pending admin approval** | M365 admin hasn't cleared the submission in [Microsoft 365 admin center → Agents → Requests](https://admin.microsoft.com/) | Follow up with M365 admin; typical SLA 1–2 business days |
| User in Teams sees "Agent not available" / "Built for your org" tab missing | User not licensed for Microsoft 365 Copilot, or in a different Power Platform environment than the agent, or admin approval hasn't propagated, or your tenant doesn't allow Power Platform apps in Teams | Check licensing, environment, approval status, and [Manage Power Platform apps in Teams](https://learn.microsoft.com/microsoftteams/manage-power-platform-apps) |
| User can open the agent and chat, but citation link returns 403 or AuthorizationFailure | The Blob URL in `source_uri` requires Entra auth the end-user doesn't have | Either grant users **Storage Blob Data Reader** on the source storage account, or layer a SAS-token rewrite proxy on top of the blob URL before chunk upload |

For the AI Search-side issues (indexer failures, vectorizer auth, blob 403s on the **indexer**, semantic ranker), see [06-troubleshooting.md § 4](./06-troubleshooting.md#4--ai-search-index--indexer).

---

## Reference documentation

- [Copilot Studio overview](https://learn.microsoft.com/microsoft-copilot-studio/fundamentals-what-is-copilot-studio)
- [Copilot Studio licensing](https://learn.microsoft.com/microsoft-copilot-studio/requirements-licensing-subscriptions)
- [Add Azure AI Search as a knowledge source](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-azure-ai-search) — includes citation field convention and VNet support
- [Knowledge sources summary](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-copilot-studio) — includes the **Allow ungrounded responses** setting
- [Orchestrate agent behavior with generative AI](https://learn.microsoft.com/microsoft-copilot-studio/advanced-generative-actions)
- [Connect and configure an agent for Teams and Microsoft 365](https://learn.microsoft.com/microsoft-copilot-studio/publication-add-bot-to-microsoft-teams) — single combined channel reference
- [Publish agents for Microsoft 365 Copilot](https://learn.microsoft.com/microsoft-365/copilot/extensibility/publish)
- [Manage requested Copilot Studio agents](https://learn.microsoft.com/microsoft-365/copilot/agent-essentials/agent-lifecycle/agent-copilot-studio-requested) — admin approval flow
- [Manage Power Platform apps in Teams](https://learn.microsoft.com/microsoftteams/manage-power-platform-apps)
- [Power Platform environments overview](https://learn.microsoft.com/power-platform/admin/environments-overview)
- [Index file content and metadata by using Azure AI Search](https://learn.microsoft.com/azure/architecture/ai-ml/architecture/search-blob-metadata) — `metadata_storage_path` convention

---

*Last updated: 2026-05-24*
