terraform {
  backend "s3" {
    bucket         = "clevertap-terraform-state-staging"
    key            = "staging/us-east-1/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "clevertap-terraform-locks-staging"
    encrypt        = true
    kms_key_id     = "alias/clevertap-terraform-state-staging"
  }
}
