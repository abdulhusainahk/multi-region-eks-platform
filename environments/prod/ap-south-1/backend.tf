terraform {
  backend "s3" {
    bucket         = "clevertap-terraform-state-prod"
    key            = "prod/ap-south-1/terraform.tfstate"
    region         = "us-east-1" # State bucket lives in us-east-1 (single state region)
    dynamodb_table = "clevertap-terraform-locks-prod"
    encrypt        = true
    kms_key_id     = "alias/clevertap-terraform-state-prod"
  }
}
