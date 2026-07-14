# One image for every serverless lane. The dataset is baked in at build
# time; a cold instance pulls the image and serves — no data download on boot.
#
# The AWS Lambda Web Adapter is copied in unconditionally: on Lambda it is
# loaded as an extension and translates invocations into HTTP against the
# uvicorn app; on Cloud Run / Azure Container Apps it is an inert, unused file.
# That is what lets the SAME image run on all three.

FROM python:3.13-slim AS builder
WORKDIR /src
COPY pyproject.toml README.md ./
COPY src ./src
RUN pip install --no-cache-dir .[agent]
# bake the store into the image (swap the CREATE TABLE in init_db.py for your data)
ENV CHDB_DATA_PATH=/app/chdb-data
ARG BAKE_PARTITIONS=1
ENV BAKE_PARTITIONS=${BAKE_PARTITIONS}
RUN python -m chdb_serverless.init_db

FROM python:3.13-slim
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.9.1 /lambda-adapter /opt/extensions/lambda-adapter
WORKDIR /app
RUN useradd -m -u 1000 appuser
COPY --from=builder /usr/local/lib/python3.13/site-packages /usr/local/lib/python3.13/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder --chown=appuser:appuser /app/chdb-data /app/chdb-data
ENV PYTHONUNBUFFERED=1
ENV CHDB_STORE=local:/app/chdb-data
USER appuser
EXPOSE 8080
CMD ["python", "-m", "chdb_serverless.server"]
