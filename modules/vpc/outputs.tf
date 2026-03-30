###############################################################################
# VPC Module — outputs.tf
###############################################################################

output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "The primary CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "List of IDs of public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of IDs of private subnets"
  value       = aws_subnet.private[*].id
}

output "intra_subnet_ids" {
  description = "List of IDs of intra (database) subnets"
  value       = aws_subnet.intra[*].id
}

output "public_route_table_id" {
  description = "ID of the public route table"
  value       = length(aws_route_table.public) > 0 ? aws_route_table.public[0].id : null
}

output "private_route_table_ids" {
  description = "List of IDs of private route tables (one per AZ)"
  value       = aws_route_table.private[*].id
}

output "intra_route_table_id" {
  description = "ID of the intra (database) route table"
  value       = length(aws_route_table.intra) > 0 ? aws_route_table.intra[0].id : null
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs"
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_public_ips" {
  description = "List of Elastic IP addresses associated with NAT Gateways"
  value       = aws_eip.nat[*].public_ip
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = length(aws_internet_gateway.this) > 0 ? aws_internet_gateway.this[0].id : null
}

output "flow_logs_s3_bucket_name" {
  description = "Name of the S3 bucket receiving VPC Flow Logs"
  value       = local.create_flow_logs_bucket ? aws_s3_bucket.flow_logs[0].id : var.flow_logs_s3_bucket_name
}

output "flow_logs_s3_bucket_arn" {
  description = "ARN of the S3 bucket receiving VPC Flow Logs"
  value       = local.create_flow_logs_bucket ? aws_s3_bucket.flow_logs[0].arn : null
}

output "tgw_attachment_id" {
  description = "ID of the Transit Gateway VPC Attachment (empty if TGW not used)"
  value       = length(aws_ec2_transit_gateway_vpc_attachment.this) > 0 ? aws_ec2_transit_gateway_vpc_attachment.this[0].id : null
}
