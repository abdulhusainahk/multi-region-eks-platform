# Alertmanager configuration template
# Variables injected from AWS Secrets Manager:
#   pagerduty_routing_key, slack_webhook_url, slack_api_url
---
global:
  resolve_timeout: 5m
  slack_api_url: ${slack_api_url}

route:
  receiver: slack-default
  group_by: [alertname, cluster, service]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - match:
        severity: critical
      receiver: pagerduty-critical
      continue: true
    - match:
        severity: critical
      receiver: slack-critical
    - match:
        severity: warning
      receiver: slack-warning
    - match:
        severity: info
      receiver: slack-info

receivers:
  - name: slack-default
    slack_configs:
      - channel: "#alerts"
        title: "{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}"
        text: "{{ range .Alerts }}{{ .Annotations.description }}{{ end }}"

  - name: slack-critical
    slack_configs:
      - channel: "#incidents"
        color: danger
        title: "🚨 {{ range .Alerts }}{{ .Annotations.summary }}{{ end }}"
        text: |
          {{ range .Alerts }}
          *Alert:* {{ .Annotations.summary }}
          *Description:* {{ .Annotations.description }}
          *Runbook:* {{ .Annotations.runbook_url }}
          {{ end }}

  - name: slack-warning
    slack_configs:
      - channel: "#alerts"
        color: warning

  - name: slack-info
    slack_configs:
      - channel: "#observability"

  - name: pagerduty-critical
    pagerduty_configs:
      - routing_key: ${pagerduty_routing_key}
        description: "{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}"
        details:
          runbook_url: "{{ range .Alerts }}{{ .Annotations.runbook_url }}{{ end }}"

inhibit_rules:
  - source_matchers:
      - alertname = "EventIngestionAvailabilitySLOCritical"
    target_matchers:
      - alertname =~ "KubePodCrashLooping|KubePodNotReady"
    equal: [service, namespace]
  - source_matchers:
      - severity = critical
    target_matchers:
      - severity = warning
    equal: [alertname, cluster, service]
