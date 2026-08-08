terraform {
  backend "s3" {
    bucket         = "bank-tfstate-nonprod"
    key            = "dev/platform/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "terraform-lock-nonprod"
  }
}
