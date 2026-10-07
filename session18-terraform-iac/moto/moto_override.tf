# Local-only override: points the aws provider at moto (a local AWS emulator)
# instead of real AWS. I had no AWS account for this session.
#
# Terraform merges any *_override.tf file into the matching block of the main
# config, so main.tf / providers.tf stay exactly as the instructor wrote them.
# Copy this file into a lab folder to run it locally, delete it to run on AWS.
provider "aws" {
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3  = "http://localhost:5000"
    sts = "http://localhost:5000"
    iam = "http://localhost:5000"
  }
}
