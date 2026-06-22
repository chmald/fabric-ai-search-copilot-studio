"""
main.py — minimal chat front end for a Microsoft Foundry agent.

A single-file FastAPI app that relays user messages to a published Foundry
agent (built per docs/03d) and streams the reply back to a small static UI.
It is intentionally tiny: no database, no session store, no SDK beyond the
Foundry projects client and azure-identity.

------------------------------------------------------------------------------
Two identity modes (selected by the ENABLE_OBO env var)
------------------------------------------------------------------------------
* MI mode (ENABLE_OBO != "true"; the default):
    The app calls the agent as its own **user-assigned managed identity**.
    Simple, no Entra app registration. Sufficient when the agent uses only the
    Azure AI Search tool. The Microsoft Fabric data agent tool will NOT receive
    a per-user identity in this mode.

* OBO mode (ENABLE_OBO == "true"):
    The app calls the agent **on behalf of the signed-in user** using a
    secretless On-Behalf-Of exchange. Container Apps' built-in authentication
    (Easy Auth) signs the user in and injects their access token; the app
    exchanges it for a Foundry-scoped token whose identity is the user. This is
    REQUIRED for the Fabric data agent tool so Fabric enforces row-/object-level
    security, Purview, and DLP per user. The client assertion for the
    confidential-client exchange is the managed identity's own token for the
    token-exchange audience (a federated identity credential), so no client
    secret is stored. See docs/08 and docs/09 for the identity model.

------------------------------------------------------------------------------
Configuration (environment variables)
------------------------------------------------------------------------------
    FOUNDRY_PROJECT_ENDPOINT  Foundry project endpoint, e.g.
                              https://<resource>.services.ai.azure.com/api/projects/<project>
    AGENT_ID                  Published agent identifier (e.g. "hr-knowledge-agent")
    AZURE_CLIENT_ID           Client ID of the user-assigned managed identity
                              assigned to the Container App (used in both modes:
                              MI mode calls the agent with it; OBO mode uses it
                              as the federated client assertion).
    ENABLE_OBO                "true" to enable On-Behalf-Of (default: unset/false)
    OBO_CLIENT_ID             (OBO only) App registration client ID for the
                              confidential-client OBO exchange.
    AZURE_TENANT_ID           (OBO only) Tenant ID for the OBO authority.
    AGENT_TOKEN_SCOPE         Token scope/audience for the Foundry data plane.
                              Default: https://ai.azure.com/.default
                              (verify against current Microsoft Learn).

Nothing customer-specific or secret is baked into this image — all values come
from the environment at runtime.
"""

from __future__ import annotations

import logging
import os
from functools import lru_cache
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("foundry-webapp")

# --- Configuration -----------------------------------------------------------

PROJECT_ENDPOINT = os.getenv("FOUNDRY_PROJECT_ENDPOINT", "").rstrip("/")
AGENT_ID = os.getenv("AGENT_ID", "")
UAMI_CLIENT_ID = os.getenv("AZURE_CLIENT_ID", "")
ENABLE_OBO = os.getenv("ENABLE_OBO", "").lower() == "true"
OBO_CLIENT_ID = os.getenv("OBO_CLIENT_ID", "")
TENANT_ID = os.getenv("AZURE_TENANT_ID", "")
AGENT_TOKEN_SCOPE = os.getenv("AGENT_TOKEN_SCOPE", "https://ai.azure.com/.default")
# Audience for the secretless federated-credential (managed identity) assertion
# used by the confidential-client OBO exchange.
TOKEN_EXCHANGE_SCOPE = "api://AzureADTokenExchange/.default"

STATIC_DIR = Path(__file__).parent / "static"

app = FastAPI(title="Foundry agent chat", version="1.0.0")


class ChatRequest(BaseModel):
    message: str
    thread_id: Optional[str] = None


# --- Credential construction -------------------------------------------------


@lru_cache(maxsize=1)
def _mi_credential():
    """Managed-identity credential — the OBO client-assertion source (Azure only)."""
    from azure.identity import ManagedIdentityCredential

    kwargs = {"client_id": UAMI_CLIENT_ID} if UAMI_CLIENT_ID else {}
    return ManagedIdentityCredential(**kwargs)


@lru_cache(maxsize=1)
def _default_credential():
    """
    Credential for MI-mode agent calls.

    DefaultAzureCredential resolves to the user-assigned managed identity inside
    Container Apps and to the developer's `az login` identity when run locally, so
    the same image works in both places.
    """
    from azure.identity import DefaultAzureCredential

    kwargs = {"managed_identity_client_id": UAMI_CLIENT_ID} if UAMI_CLIENT_ID else {}
    return DefaultAzureCredential(**kwargs)


def _obo_credential(user_assertion: str):
    """
    Secretless On-Behalf-Of credential.

    The confidential-client assertion is the managed identity's own token for
    the token-exchange audience (a federated identity credential configured on
    the app registration), so no client secret is required.
    """
    from azure.identity import OnBehalfOfCredential

    def _client_assertion() -> str:
        return _mi_credential().get_token(TOKEN_EXCHANGE_SCOPE).token

    return OnBehalfOfCredential(
        tenant_id=TENANT_ID,
        client_id=OBO_CLIENT_ID,
        user_assertion=user_assertion,
        client_assertion_func=_client_assertion,
    )


def _resolve_credential(user_assertion: Optional[str]):
    if ENABLE_OBO:
        if not user_assertion:
            raise HTTPException(
                status_code=401,
                detail="OBO mode is enabled but no user token was provided. "
                "Ensure Container Apps authentication (Easy Auth) is configured.",
            )
        return _obo_credential(user_assertion)
    return _default_credential()


# --- Foundry agent call ------------------------------------------------------


def _last_assistant_text(messages) -> str:
    """Extract the most recent assistant text from an agent message list."""
    for msg in messages:
        if getattr(msg, "role", None) != "assistant":
            continue
        # The SDK exposes a text_messages helper on newer versions; fall back to
        # walking the content parts for portability across SDK revisions.
        text_messages = getattr(msg, "text_messages", None)
        if text_messages:
            return text_messages[-1].text.value
        for part in getattr(msg, "content", []) or []:
            text = getattr(getattr(part, "text", None), "value", None)
            if text:
                return text
    return ""


# NOTE: uses the azure-ai-projects v1.x agents surface (threads/messages/runs), which is
# documented to sunset 2026-08-26 with the classic Assistants API. Migrate to the v2.x
# Responses API (openai.responses.create / conversations) before then — see
# https://learn.microsoft.com/azure/foundry/agents/how-to/migrate
def _ask_agent(credential, message: str, thread_id: Optional[str]) -> tuple[str, str]:
    """Send one message to the agent and return (reply_text, thread_id)."""
    from azure.ai.projects import AIProjectClient

    if not PROJECT_ENDPOINT or not AGENT_ID:
        raise HTTPException(
            status_code=500,
            detail="Server is missing FOUNDRY_PROJECT_ENDPOINT or AGENT_ID.",
        )

    with AIProjectClient(endpoint=PROJECT_ENDPOINT, credential=credential) as project:
        agents = project.agents
        tid = thread_id or agents.threads.create().id
        agents.messages.create(thread_id=tid, role="user", content=message)
        run = agents.runs.create_and_process(thread_id=tid, agent_id=AGENT_ID)
        if getattr(run, "status", None) == "failed":
            detail = getattr(run, "last_error", None) or "agent run failed"
            raise HTTPException(status_code=502, detail=f"Agent run failed: {detail}")
        reply = _last_assistant_text(agents.messages.list(thread_id=tid))
        return reply, tid


# --- Routes ------------------------------------------------------------------


@app.get("/healthz")
def healthz():
    """Unauthenticated liveness probe."""
    return {
        "status": "ok",
        "oboEnabled": ENABLE_OBO,
        "agentConfigured": bool(PROJECT_ENDPOINT and AGENT_ID),
    }


@app.post("/api/chat")
def chat(
    body: ChatRequest,
    x_ms_token_aad_access_token: Optional[str] = Header(default=None),
):
    """Relay one user message to the agent and return its reply."""
    if not body.message.strip():
        raise HTTPException(status_code=400, detail="message must not be empty.")

    credential = _resolve_credential(x_ms_token_aad_access_token)
    try:
        reply, thread_id = _ask_agent(credential, body.message, body.thread_id)
    except HTTPException:
        raise
    except Exception as exc:  # surface a clean error to the UI
        log.exception("agent call failed")
        raise HTTPException(status_code=502, detail=f"Agent call failed: {exc}") from exc

    return JSONResponse({"reply": reply, "thread_id": thread_id})


@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")


# Static assets (index.html, app.js, styles) served from ./static.
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
