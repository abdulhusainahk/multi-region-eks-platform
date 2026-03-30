# Loki Helm values template
# Variables injected by Terraform: loki_bucket, loki_region, loki_role_arn
---
loki:
  auth_enabled: false
  storage:
    type: s3
    s3:
      endpoint: s3.${loki_region}.amazonaws.com
      region: ${loki_region}
      bucketnames: ${loki_bucket}
      s3ForcePathStyle: false
      insecure: false
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  limits_config:
    retention_period: 90d
    ingestion_rate_mb: 64
    ingestion_burst_size_mb: 128
    max_streams_per_user: 0
    max_cache_freshness_per_query: 10m
    split_queries_by_interval: 24h
    max_query_parallelism: 32

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: ${loki_role_arn}

write:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 1Gi

read:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 1Gi

backend:
  replicas: 3

gateway:
  enabled: true
  replicas: 2
