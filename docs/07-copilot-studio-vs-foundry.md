# 07 — Copilot Studio vs. Microsoft Foundry Agent Service

A decision guide for **Layer 3 (the conversational layer)** of this pattern. Both options sit on the **same ingestion + platform substrate** — the choice is purely *how users talk to the index*, and it is driven mostly by **licensing, governance model, and how much engineering you want to own.**

> **Summary.** Use **Copilot Studio** ([03c](./03c-copilot-studio-setup.md)) for the lowest-code, fully-GA path when the audience is small or Copilot Studio capacity is already licensed. Use **Microsoft Foundry Agent Service** ([03d](./03d-foundry-agent-setup.md)) when **premium-connector / message-capacity licensing is the constraint**, when you need **richer orchestration**, or when you want everything under **Azure RBAC + consumption billing** — noting that **M365/Teams publishing from Foundry is currently preview.**

---

## The shared substrate (identical on both paths)

Nothing below Layer 3 changes. Both agents read the **same** `idx-rag-documents` index:

```
Fabric ingest (03b)  →  Blob raw/ + chunks/  →  AI Search hybrid index
                                                 (integrated vectorizer + semantic ranker)
                                                 served by the Foundry model gateway
```

So this is **not** a re-platforming decision — you can build one, and swap to the other later without touching ingestion, storage, or the index. The migration cost is one layer, not the stack.

---

## Side-by-side

| Dimension | Copilot Studio (03c) | Microsoft Foundry Agent Service (03d) |
|---|---|---|
| **Runtime** | Power Platform (Copilot Studio) | Microsoft Foundry Agent Service |
| **Build effort** | Lowest-code — portal config only | Low/medium-code — portal + Agents Toolkit wrapper for publishing |
| **Answer-generation model** | Copilot Studio **host model** (no deployment to manage) | **Your** chat deployment (e.g. `gpt-4o`) — required, you size + bill it |
| **AI Search grounding** | Native knowledge source | **Azure AI Search tool** |
| **Fabric Data Agent** | Connector (premium / capacity-billed) | Native **Microsoft Fabric tool** |
| **Orchestration ceiling** | Single-agent knowledge Q&A + topics | Multi-tool routing, multi-agent, custom tool calling, code interpreter |
| **M365 + Teams publishing** | **GA**, one-click combined channel | **Preview** — custom engine agent via M365 Agents SDK |
| **Citations / answer UX** | Built-in citation rendering | You assemble citations in the agent + channel |
| **Per-user security trimming** | Entra ID Integrated identity; doc-filter injection deployment-specific | Caller OBO identity; AI Search `$filter` injection + **Fabric RLS native** |
| **Billing model** | Copilot Studio **message capacity** (packs) or per-user license | **Azure consumption** — tokens + tool calls + search QU + Fabric capacity |
| **Governance plane** | Power Platform (environments, DLP, admin center) | Azure (RBAC, Policy, Private Link) + Teams admin for the channel |
| **Identity for tools** | Power Platform data connection (Entra Integrated / SP) | Project **managed identity** + caller **on-behalf-of** |
| **Maturity for production** | Fully GA today | Runtime/tools GA-to-preview; **publishing surface is preview** |

---

## Licensing deep-dive

This is the section that decides most deployments.

### Why Copilot Studio surfaces a licensing wall

A Microsoft 365 Copilot license covers **declarative agents** — agents grounded on M365 content (SharePoint, Graph) built in Copilot Studio's M365 surface. The moment an agent reaches **outside** that boundary — here, an **Azure AI Search** knowledge source **and** a **Fabric Data Agent** — those become **premium / capacity-billed connectors**, and the agent is metered against **Copilot Studio message capacity** (consumption packs) or requires per-user Copilot Studio licensing **on top of** M365 Copilot. For a broad rollout, that recurring per-message/per-user cost is the limiting factor.

### Why Foundry removes it

Foundry Agent Service bills the **runtime as Azure consumption**: chat-model tokens, tool invocations, AI Search query units, and Fabric capacity — all on the **Azure subscription** you already fund. The **premium-connector licensing disappears** because the connectors become native Foundry **tools**, not Power Platform connectors. **End users still consume on their existing M365 Copilot license** (the custom engine agent rides the M365/Teams surface). You move a Power Platform line item to Azure PAYG.

### Cost considerations and caveats

- This is a **cost shift, not a cost elimination.** Model and tool consumption is real Azure spend — quantify it before assuming savings. For **small audiences**, Copilot Studio capacity can still be cheaper than operating a Foundry agent.
- You now **own the chat model**: deployment, quota, capacity, and the answer-quality settings that Copilot Studio otherwise manages.
- **M365/Teams publishing is preview** — a production commitment carries preview risk.

---

## Copilot Studio — pros & cons

**Pros**
- **Lowest time-to-value** — a working grounded agent in well under an hour, no Azure agent infra.
- **Fully GA** end-to-end, including one-click **Teams + M365 Copilot** publishing.
- **No model to operate** — answers run on the managed host model; no quota/capacity work.
- **Built-in citation UX** and grounding toggles ("don't use general knowledge", "no ungrounded answers").
- **Maker-friendly** — a non-developer can own it; governed through Power Platform DLP + environments.

**Cons**
- **Premium-connector / message-capacity licensing** once you connect Azure AI Search + Fabric Data Agent — the most common constraint.
- **Orchestration ceiling** — great at knowledge Q&A, weaker at multi-tool routing / agentic actions.
- **Per-user document trimming** (group-ID filter injection) is **deployment-specific**, not guaranteed out-of-the-box.
- **Consumption is per-message** and can be hard to predict at broad-rollout scale.
- Less control over retrieval/answer internals than owning the model.

---

## Foundry Agent Service — pros & cons

**Pros**
- **Removes the premium-connector licensing constraint** — runtime is Azure consumption; AI Search + Fabric are native tools.
- **Richer orchestration** — multi-tool routing (AI Search vs. Fabric Data Agent vs. both), multi-agent, custom tool calling, code interpreter.
- **Native Fabric Data Agent tool with on-behalf-of identity** → **per-user RLS/OLS** on structured HR data, enforced by Fabric (cleaner than the document-side filter story).
- **Unified Azure governance** — RBAC, Private Link / VNet, Policy, managed identity, no keys.
- **Strategic Microsoft direction** for pro-code agents; headroom to grow the agent beyond Q&A.
- **Predictable Azure PAYG billing** on the subscription you already run.

**Cons**
- **M365/Teams publishing is PREVIEW** — the biggest production caveat; re-verify before committing dates.
- **More to build & operate** — Foundry project, chat deployment + quota, the Agents Toolkit / bot wrapper, Entra bot identity, SSO for caller identity.
- **You own the model** — sizing, capacity, cost, answer-quality tuning.
- **Citation/answer UX is more DIY** than Copilot Studio's built-in rendering.
- **Governance is split** across Azure (runtime/tools) + Teams admin (channel) — two planes, not one.
- **Requires Azure dev skills** + consumption budget; not a non-developer maker tool.

---

## Decision matrix

| If your deployment… | Choose |
|---|---|
| Hit **premium-connector / Copilot Studio capacity licensing** as a constraint (AI Search + Fabric Data Agent) | **Foundry (03d)** |
| Needs **structured-data Q&A with per-user row-level security** (HR comp, PII) | **Foundry (03d)** — native Fabric RLS via OBO |
| Needs **multi-tool routing, agentic actions, or custom tool calling** | **Foundry (03d)** |
| Is **Azure-committed** and wants **consumption billing + Azure RBAC/Private Link** | **Foundry (03d)** |
| **Cannot take a preview dependency** for production | **Copilot Studio (03c)** |
| Is **unstructured-document RAG only**, small audience, CS capacity already licensed | **Copilot Studio (03c)** |
| Has **no Azure dev capacity**, needs a **maker-owned** agent fast | **Copilot Studio (03c)** |
| Needs **GA + one-click Teams/M365 publish today** | **Copilot Studio (03c)** |

When the column is split (e.g. licensing says Foundry but you can't take preview risk), surface the tension explicitly and weigh **cost now vs. preview risk** — don't silently pick.

---

## Migration note — you are not locked in

Because Layers 1–2 are shared, moving between paths is a **Layer-3-only** effort:

- **Copilot Studio → Foundry** (the licensing-driven direction): deploy a chat model, add the AI Search tool (point at the same index), grant the project MI **Search Index Data Reader**, add the Fabric tool, wrap with the Agents Toolkit, publish. No re-indexing.
- **Foundry → Copilot Studio** (fall back if the preview dependency is a concern): bind the same index as a Copilot Studio knowledge source and publish the combined channel. The index, Blob, and Fabric pipeline are untouched.

Build the path that fits your constraints **now**; keep the other as a documented fallback.

---

## References

- Copilot Studio path: [03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md)
- Foundry path: [03d-foundry-agent-setup.md](./03d-foundry-agent-setup.md)
- Architecture (Layer 3 alternatives): [01-architecture.md](./01-architecture.md#layer-3--conversational-layer-copilot-studio--purple)
- [Copilot Studio licensing](https://learn.microsoft.com/microsoft-copilot-studio/requirements-licensing-subscriptions) · [Microsoft Foundry Agent Service overview](https://learn.microsoft.com/azure/foundry/agents/overview)

---

*Last updated: 2026-06-09*
