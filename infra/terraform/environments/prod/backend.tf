# Author: Mengty LIM
# Remote state — encrypted, versioned, locked, access-restricted.
#
# One state file per environment PER LAYER. A mistake in `network` must not be
# able to destroy `data`. Layers here: network | platform | data.
# This file is the `platform` layer for prod.
#
# Bootstrap the bucket + lock table once from global/bootstrap/, never by hand.

terraform {
  backend "s3" {
    bucket = "bank-tfstate-prod"
    key    = "prod/platform/terraform.tfstate"
    region = "eu-central-1"

    encrypt        = true
    kms_key_id     = "alias/tfstate-prod"
    dynamodb_table = "terraform-lock-prod"

    # MinIO/on-prem S3 alternative — uncomment and drop the AWS-only fields:
    # endpoints                   = { s3 = "https://minio.bank.internal:9000" }
    # use_path_style              = true
    # skip_credentials_validation = true
    # skip_region_validation      = true
    # skip_requesting_account_id  = true
  }
}

# Treat state as a secret: it contains resource attributes, and marking an
# output `sensitive` hides it from the CLI, not from the state file.
