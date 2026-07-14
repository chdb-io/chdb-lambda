# chdb-serverless

Run a [chDB](https://github.com/chdb-io/chdb) (in-process ClickHouse) analyst
on serverless — **one app and one image** across AWS Lambda, Google Cloud
Run, and Azure Container Apps, with two plug seams that keep the core
unchanged as you grow:

- **store seam** — `local:` (this package, L1) → `durable:` (S3-backed object, L2) → `memory:` (analytical agent memory, L3), chosen by `CHDB_STORE`;
- **model seam** — Anthropic / OpenAI / any OpenAI-compatible server, chosen by `CHDB_MODEL`, so the analyst is not anchored to one LLM.

> This repo is the base. The walkthroughs — why in-process, the cold-start
> comparison across clouds, the tier ladder — live in the
> [chDB cookbook serverless series](https://github.com/chdb-io/cookbook/tree/main/serverless-analyst).
> Heritage: this repo pioneered chDB-on-Lambda in 2023 (thanks @lmangani);
> the maintained, multi-cloud version is here.

## Use as a template (clone and deploy)

```bash
git clone https://github.com/chdb-io/chdb-lambda
cd chdb-lambda
export ANTHROPIC_API_KEY=sk-...        # optional — omit for /query only
deploy/aws-lambda/deploy.sh            # or gcp-cloud-run/ or azure-container-apps/
```

**Auth posture (read before deploying):** `/query` runs caller-supplied
ClickHouse SQL and `/ask` spends model tokens, so every lane deploys
**non-public by default** — AWS Lambda uses an `AWS_IAM` Function URL, and
Cloud Run / Container Apps use private ingress. Set `PUBLIC=1` to opt into an
unauthenticated endpoint for a throwaway demo, and put your own auth in front
before exposing anything real.

## Use as a package (import, don't copy)

```bash
pip install chdb-serverless[anthropic]   # or [openai]
```

```python
from chdb_serverless import analyst_app, open_store
app = analyst_app()          # FastAPI: /health /query /ask
store = open_store()         # CHDB_STORE selects the tier
```

## Seams

| Env | Values | Meaning |
|---|---|---|
| `CHDB_STORE` | `local:/path` · `durable:s3://…` · `memory:s3://…` | which tier (L1 now; L2/L3 via extras) |
| `CHDB_MODEL` | `anthropic:claude-opus-4-8` · `openai:gpt-4.1` · `openai:llama3@http://host/v1` | which LLM (any OpenAI-compatible server via `@base_url`) |

Extras: `[anthropic]` `[openai]` (LLM providers), `[durable]` (L2), `[memory]` (L3).

## Layout

```
src/chdb_serverless/   app: server.py (/health /query /ask), agent.py, store.py, models/
Dockerfile             one image; bakes the dataset; carries the Lambda Web Adapter (inert off Lambda)
deploy/                per-cloud deploy.sh + teardown.sh (aws-lambda / gcp-cloud-run / azure-container-apps)
```
