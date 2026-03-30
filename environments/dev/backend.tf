###############################################################################
# Backend configuration for dev environment
# State stored in S3 with DynamoDB locking
###############################################################################
terraform {
  backend "s3" {
    bucket         = "clevertap-terraform-state-dev"
    key            = "dev/us-east-1/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "clevertap-terraform-locks-dev"
    encrypt        = true
    kms_key_id     = "alias/clevertap-terraform-state-dev"
  }
}
