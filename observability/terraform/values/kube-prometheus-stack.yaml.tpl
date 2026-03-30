# kube-prometheus-stack Helm values template
# Variables injected by Terraform: cluster_name, environment, grafana_admin_pass,
# thanos_bucket, thanos_region, thanos_role_arn, alertmanager_secret
---
fullnameOverride: kube-prometheus-stack

global:
  rbac:
    create: true

prometheus:
  prometheusSpec:
    retention: 15d
    retentionSize: 50GB
    replicas: 2
    resources:
      requests:
        cpu: 1000m
        memory: 4Gi
      limits:
        memory: 8Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: gp3
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 100Gi
    externalLabels:
      cluster: ${cluster_name}
      environment: ${environment}
    additionalScrapeConfigsSecret: {}
    ruleSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    # Thanos sidecar for remote storage
    thanos:
      image: quay.io/thanos/thanos:v0.35.0
      objectStorageConfig:
        secret:
          type: S3
          config:
            bucket: ${thanos_bucket}
            endpoint: s3.${thanos_region}.amazonaws.com
            region: ${thanos_region}
            sse_config:
              type: SSE-S3

alertmanager:
  alertmanagerSpec:
    replicas: 2
    configSecret: ${alertmanager_secret}

grafana:
  enabled: true
  adminPassword: ${grafana_admin_pass}
  persistence:
    enabled: true
    size: 10Gi
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
    datasources:
      enabled: true
  additionalDataSources:
    - name: Thanos
      type: prometheus
      url: http://thanos-query.monitoring.svc.cluster.local:9090
      access: proxy
      isDefault: true
    - name: Loki
      type: loki
      url: http://loki-gateway.monitoring.svc.cluster.local
      access: proxy
    - name: Tempo
      type: tempo
      url: http://tempo.monitoring.svc.cluster.local:3100
      access: proxy

kube-state-metrics:
  enabled: true

node-exporter:
  enabled: true
