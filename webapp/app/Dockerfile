# Minimal single-stage runtime image for the chat front end.
#
# Built and pushed by scripts/deploy-webapp.ps1 via `az acr build` (Azure Container
# Registry build task) — no local Docker daemon required.
#
# Uses the standard slim Python image. If your ACR build hits Docker Hub rate limits,
# swap the base for an MCR-hosted Python image (no anonymous pull limits).

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8000

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . ./

EXPOSE 8000

# uvicorn binds 0.0.0.0:$PORT; Container Apps maps ingress targetPort to it.
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT}"]
