# Local-only override: points the aws provider at moto (a local AWS emulator on
# localhost:5000) instead of real AWS. I have no AWS account, so this is the only
# way I could run plan/apply/destroy for this folder.
#
# Terraform merges any *_override.tf file into the matching block of the main
# config, so versions.tf keeps the instructor's real `provider "aws"` untouched.
# Copy this file into ../ to run against moto, delete the copy afterwards.
provider "aws" {
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    ec2         = "http://localhost:5000"
    iam         = "http://localhost:5000"
    sts         = "http://localhost:5000"
    eks         = "http://localhost:5000"
    kms         = "http://localhost:5000"
    logs        = "http://localhost:5000"
    ssm         = "http://localhost:5000"
    autoscaling = "http://localhost:5000"
  }
}
