# Tempo Distributed Helm values template
# Variables injected by Terraform: tempo_bucket, tempo_region, tempo_role_arn
---
storage:
  trace:
    backend: s3
    s3:
      bucket: ${tempo_bucket}
      endpoint: s3.${tempo_region}.amazonaws.com
      region: ${tempo_region}
      insecure: false

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: ${tempo_role_arn}

traces:
  otlp:
    grpc:
      enabled: true
    http:
      enabled: true

distributor:
  replicas: 2

ingester:
  replicas: 3
  config:
    max_block_duration: 30m

querier:
  replicas: 2

queryFrontend:
  replicas: 2

compactor:
  replicas: 1
  config:
    compaction:
      block_retention: 720h  # 30 days

global_overrides:
  max_bytes_per_trace: 5000000
  ingestion_rate_limit_bytes: 15000000
  ingestion_burst_size_bytes: 20000000
