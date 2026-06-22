# Structured sample data — Fabric Data Agent

This folder holds the **structured data** for the optional **Microsoft Fabric Data Agent** integration on the [Microsoft Foundry agent path (03d)](../docs/03d-foundry-agent-setup.md). Load these tables into a Fabric Lakehouse and point a Data Agent at them — full steps in [docs/03e-fabric-data-agent.md](../docs/03e-fabric-data-agent.md).

> **The document corpus is *not* in this repo — by design.** The unstructured sample files (offer letters, NDAs, severance, contractor agreements) are **standalone**: you upload your own document set into the ingestion source to trigger the Fabric → Blob → AI Search flow ([03b § F4](../docs/03b-fabric-setup.md)). This repo ships only the **structured** companion data, which is all the Fabric Data Agent integration needs.

> **100% synthetic.** Every name, employer, and figure below is fictitious. The rows correspond to a standard synthetic HR document set via the `source_pdf` / `source_document` key — so when that document set is uploaded to the ingestion flow, the AI Search (document) answers and the Fabric Data Agent (structured) answers line up for the same person. **Never replace these with real HR data in a committed file.**

---

## Files

```
samples/
├── README.md                       (this file)
└── structured/
    ├── employees.csv   (15 rows)   one row per offer letter — the "active workforce"
    └── agreements.csv  (30 rows)   one row per document across all four doc types
```

### `employees.csv`

`employee_id, name, employer, region, position_title, level, base_salary, currency, pay_frequency, signing_bonus, equity_grant, start_date, non_compete_months, source_document`

### `agreements.csv`

`document_id, document_type, employer, counterparty, region, effective_date, amount, currency, amount_basis, term_months, pages, source_pdf`

> **`amount_basis`** (`annual` / `hourly` / `lump_sum` / `fixed_fee` / `milestone`) prevents naive aggregation across heterogeneous amounts — filter on it before averaging or summing, and don't convert across `currency`.

---

## How to use

1. Load `employees.csv` and `agreements.csv` into a Fabric Lakehouse as Delta tables (`employees`, `agreements`).
2. Create + ground + publish a Fabric Data Agent over them.
3. Connect the published Data Agent to the Foundry agent as its Microsoft Fabric knowledge tool.

All three steps are in **[docs/03e-fabric-data-agent.md](../docs/03e-fabric-data-agent.md)**.

---

## Sample questions (validate the Data Agent)

- How many offer letters are for executive-level roles? *(→ 2)*
- What is the average annual base salary for US senior roles? *(→ 191,500 USD)*
- How many documents of each type are in the portfolio? *(→ 15 / 5 / 5 / 5)*
- Which severance agreements pay 12 or more months? *(→ `SEV-002`, `SEV-005`)*
- List every agreement in the DE region. *(→ `OL-012`, `OL-013`, `NDA-004`, `SEV-004`)*

For a cross-source test that exercises tool routing on the Foundry agent (structured **and** document), ask: *"For the VP of Product hire, what's the base salary **and** what does the non-compete clause say?"* — the salary comes from `agreements` / `employees`, the clause text from the uploaded `OL-003` document.
