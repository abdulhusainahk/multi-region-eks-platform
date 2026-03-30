terraform {
  backend "s3" {
    # EU state stored in a SEPARATE bucket in eu-west-1 so even Terraform
    # state never leaves the EU. The prod DynamoDB lock table is replicated
    # cross-region for availability, but the S3 bucket is eu-west-1 only.
    bucket         = "clevertap-terraform-state-prod-eu"
    key            = "prod/eu-west-1/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "clevertap-terraform-locks-prod-eu"
    encrypt        = true
    kms_key_id     = "alias/clevertap-terraform-state-prod-eu"
  }
}
