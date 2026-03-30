output "thanos_bucket_name" { value = aws_s3_bucket.thanos.id }
output "loki_bucket_name" { value = aws_s3_bucket.loki.id }
output "tempo_bucket_name" { value = aws_s3_bucket.tempo.id }
output "thanos_role_arn" { value = aws_iam_role.observability["thanos"].arn }
output "loki_role_arn" { value = aws_iam_role.observability["loki"].arn }
output "tempo_role_arn" { value = aws_iam_role.observability["tempo"].arn }
output "monitoring_namespace" { value = kubernetes_namespace_v1.monitoring.metadata[0].name }
