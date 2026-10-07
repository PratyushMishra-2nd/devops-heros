# Session 18: Terraform and Infrastructure as Code

**Pratyush Mishra · Roll No. 10486**

Worked through the Terraform lesson folders (IaC basics, architecture, providers, resources, variables, outputs, the init → plan → apply → destroy lifecycle, state) and the `terraform-s3-demo` project. I do not have an AWS account, so every `terraform` command below ran for real against **moto**, a local AWS API emulator, instead of AWS. Terraform, the AWS provider and the AWS CLI do not know the difference; they just talk to a different endpoint. Command output is copied from my terminal.

**Setup:** Ubuntu 26.04 on WSL2, Terraform v1.16.4, hashicorp/aws provider v6.67.0, AWS CLI v2, moto 5.2.3 (`motoserver/moto` container on `localhost:5000`).

---

## 0. Running without AWS: the moto override

All the lesson configs have a plain provider block such as:

```hcl
provider "aws" {
  region = "ap-south-1"
}
```

I did not want to edit those, so I used a Terraform **override file**. Any file ending in `_override.tf` is merged *into* the matching block of the normal config, instead of being treated as a second, conflicting `provider "aws"` block. `moto/moto_override.tf` adds fake credentials, skips the real-AWS checks, and points the S3/STS/IAM endpoints at moto:

```hcl
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
```

For each lab I copied it in (`cp ../moto/moto_override.tf .`) and deleted it afterwards, so the lesson folders are exactly as the instructor wrote them and would run on real AWS unchanged. `s3_use_path_style` matters: by default the provider talks to `bucket-name.s3.amazonaws.com`, which a local emulator cannot answer, so it has to use `localhost:5000/bucket-name` instead.

---

## 1. IaC basics: init, fmt, validate

`01-iac-basics/main.tf` is the smallest useful config: a `terraform {}` block that pins the provider, a `provider` block, one `aws_s3_bucket` resource and one output.

```bash
$ terraform version
Terraform v1.16.4
on linux_amd64

$ cp ../moto/moto_override.tf . && ls
README.md
main.tf
moto_override.tf

$ terraform init -no-color
Initializing the backend...

Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 6.0"...
- Installing hashicorp/aws v6.67.0...
- Installed hashicorp/aws v6.67.0 (signed by HashiCorp)

Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository
so that Terraform can guarantee to make the same selections by default when
you run "terraform init" in the future.

Terraform has been successfully initialized!
...

$ terraform fmt -check -diff && echo fmt: ok
fmt: ok

$ terraform validate -no-color
Success! The configuration is valid.
```

The point of IaC versus clicking in the console: the bucket, its name pattern and its tags are now a text file that can be reviewed in a PR, re-run to get an identical result, and deleted cleanly. `fmt -check` and `validate` are the two checks that need no cloud access at all, so they are what you put in CI first.

📸 `screenshots/01-init-fmt-validate.png`

---

## 2. Architecture and providers

How the pieces fit (`02-terraform-architecture`): **Terraform core** reads the `.tf` files and the state file and works out the dependency graph and the diff. It knows nothing about AWS. The **provider** is a separate plugin binary that core downloads during `init` and talks to over RPC; it turns "create an `aws_s3_bucket`" into the actual AWS API calls. The **state** file is Terraform's record of what it created.

`03-providers` shows where the provider comes from and how its config can be driven by a variable:

```bash
$ terraform providers

Providers required by configuration:
.
└── provider[registry.terraform.io/hashicorp/aws] ~> 6.0

$ grep -A3 "^provider" .terraform.lock.hcl && ls .terraform/providers/registry.terraform.io/hashicorp/aws/
provider "registry.terraform.io/hashicorp/aws" {
  version     = "6.67.0"
  constraints = "~> 6.0"
  hashes = [
6.67.0

$ terraform plan -no-color -var aws_region=us-east-1 | grep -E "region|Plan:"
      + bucket_region               = (known after apply)
      + bucket_regional_domain_name = (known after apply)
      + region                      = "us-east-1"
Plan: 1 to add, 0 to change, 0 to destroy.
```

`~> 6.0` means "any 6.x, never 7.0". The lock file then pins the exact version that was picked (6.67.0) plus its hashes, so a teammate running `init` next month gets the same binary instead of whatever 6.x is newest. That is why the lock file belongs in Git and `.terraform/` (the downloaded binary, hundreds of MB) does not. The instructor's `terraform-s3-demo` lock file pins 6.66.0, one version behind what my fresh `init` picked, which is exactly the drift it prevents.

---

## 3. Resources and the plan

`04-resources` and `01-iac-basics` both declare a bucket with `bucket_prefix`, so AWS (here moto) appends a random suffix and the name is globally unique.

```bash
$ terraform plan -no-color
Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
  + create

Terraform will perform the following actions:

  # aws_s3_bucket.iac_demo will be created
  + resource "aws_s3_bucket" "iac_demo" {
      + acceleration_status         = (known after apply)
      + acl                         = (known after apply)
      + arn                         = (known after apply)
      + bucket                      = (known after apply)
      + bucket_domain_name          = (known after apply)
      + bucket_namespace            = (known after apply)
      + bucket_prefix               = "session18-iac-"
      + bucket_region               = (known after apply)
      + bucket_regional_domain_name = (known after apply)
      + force_destroy               = false
      + hosted_zone_id              = (known after apply)
      + id                          = (known after apply)
      + object_lock_enabled         = (known after apply)
      + policy                      = (known after apply)
      + region                      = "ap-south-1"
      + request_payer               = (known after apply)
      + tags                        = {
          + "Environment" = "dev"
          + "Name"        = "Session 18 IaC Demo"
        }
      ...
    }

Plan: 1 to add, 0 to change, 0 to destroy.

Changes to Outputs:
  + bucket_name = (known after apply)
```

A resource address is `TYPE.NAME` (`aws_s3_bucket.iac_demo`). The `NAME` is only Terraform's label; the real bucket name is the `bucket` attribute. `(known after apply)` is everything the cloud decides: the ID, the ARN, the generated name.

---

## 4. init → plan → apply (`07-init-plan-apply`)

The safe way to apply is to save the plan and apply exactly that file, so what was reviewed is what runs:

```bash
$ terraform plan -no-color -out=tfplan | tail -6
─────────────────────────────────────────────────────────────────────────────

Saved the plan to: tfplan

To perform exactly these actions, run the following command to apply:
    terraform apply "tfplan"

$ terraform apply -no-color tfplan
aws_s3_bucket.lifecycle_demo: Creating...
aws_s3_bucket.lifecycle_demo: Creation complete after 0s [id=session18-lifecycle-b2ffeae0cf853129dac9809004]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

bucket_name = "session18-lifecycle-b2ffeae0cf853129dac9809004"

$ AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test aws --endpoint-url http://localhost:5000 --region ap-south-1 s3 ls
2026-10-07 16:56:35 session18-lifecycle-b2ffeae0cf853129dac9809004
```

The bucket exists in moto, and the AWS CLI sees it the same way it would see a real one.

### A gotcha from the emulator: tags missing after create

```bash
$ ... aws --endpoint-url http://localhost:5000 --region ap-south-1 s3api get-bucket-tagging --bucket $(terraform output -raw bucket_name)

aws: [ERROR]: An error occurred (NoSuchTagSet) when calling the GetBucketTagging operation: The TagSet does not exist

$ terraform plan -no-color -detailed-exitcode | sed -n "/will be updated/,/Plan:/p"; echo "plan exit code: ${PIPESTATUS[0]}"
  # aws_s3_bucket.lifecycle_demo will be updated in-place
  ~ resource "aws_s3_bucket" "lifecycle_demo" {
        id                          = "session18-lifecycle-b2ffeae0cf853129dac9809004"
      ~ tags                        = {
          + "Name" = "Session 18 Lifecycle Demo"
        }
      ~ tags_all                    = {
          + "Name" = "Session 18 Lifecycle Demo"
        }
        # (14 unchanged attributes hidden)
        # (2 unchanged blocks hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
plan exit code: 2

$ terraform apply -no-color -auto-approve | tail -4
Outputs:

bucket_name = "session18-lifecycle-b2ffeae0cf853129dac9809004"

$ ... s3api get-bucket-tagging --bucket $(terraform output -raw bucket_name)
{
    "TagSet": [
        {
            "Key": "Name",
            "Value": "Session 18 Lifecycle Demo"
        }
    ]
}

$ terraform plan -no-color -detailed-exitcode | tail -3; echo "plan exit code: ${PIPESTATUS[0]}"
Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
plan exit code: 0
```

Right after the first apply the bucket had no tags. Terraform noticed on the next `plan` (it refreshes against the real API every time), and a second `apply` set them through a separate `PutBucketTagging` call, after which the plan is clean. The provider sends the tags with the create call and moto ignores them there; real AWS does not have this problem. I did a second apply after every create below for the same reason. It is also a nice demo of `-detailed-exitcode`: **0 = no changes, 2 = changes pending, 1 = error**, which is what a CI drift check keys on.

📸 `screenshots/02-plan-apply-moto.png`

```bash
$ terraform state list
aws_s3_bucket.lifecycle_demo

$ terraform show -no-color | head -30
# aws_s3_bucket.lifecycle_demo:
resource "aws_s3_bucket" "lifecycle_demo" {
    acceleration_status         = null
    arn                         = "arn:aws:s3:::session18-lifecycle-b2ffeae0cf853129dac9809004"
    bucket                      = "session18-lifecycle-b2ffeae0cf853129dac9809004"
    bucket_domain_name          = "session18-lifecycle-b2ffeae0cf853129dac9809004.s3.amazonaws.com"
    bucket_namespace            = "global"
    bucket_prefix               = "session18-lifecycle-"
    bucket_region               = "ap-south-1"
    bucket_regional_domain_name = "session18-lifecycle-b2ffeae0cf853129dac9809004.s3.ap-south-1.amazonaws.com"
    force_destroy               = false
    hosted_zone_id              = "Z11RGJOFQNVJUP"
    id                          = "session18-lifecycle-b2ffeae0cf853129dac9809004"
    object_lock_enabled         = false
    policy                      = null
    region                      = "ap-south-1"
    request_payer               = null
    tags                        = {
        "Name" = "Session 18 Lifecycle Demo"
    }
    ...
}

$ terraform destroy -no-color -auto-approve | grep -E "Destroying|Destroy complete"
aws_s3_bucket.lifecycle_demo: Destroying... [id=session18-lifecycle-b2ffeae0cf853129dac9809004]
Destroy complete! Resources: 1 destroyed.
```

---

## 5. Variables and where their values come from (`05-variables`)

`main.tf` declares `aws_region`, `environment` and `project_name` with defaults, and builds the bucket prefix as `"${var.project_name}-${var.environment}-"`. I fed values in four different ways:

```bash
$ terraform plan -no-color | grep -E "bucket_prefix|Project|Environment"
      + bucket_prefix               = "terraform-training-dev-"
          + "Environment" = "dev"
          + "Project"     = "terraform-training"
...

$ cp terraform.tfvars.example terraform.tfvars && cat terraform.tfvars && terraform plan -no-color | grep -E "bucket_prefix|Project|Environment"
aws_region   = "ap-south-1"
environment  = "dev"
project_name = "student-project"
      + bucket_prefix               = "student-project-dev-"
          + "Environment" = "dev"
          + "Project"     = "student-project"
...

$ terraform plan -no-color -var environment=prod | grep -E "bucket_prefix|Project|Environment"
      + bucket_prefix               = "student-project-prod-"
          + "Environment" = "prod"
          + "Project"     = "student-project"
...

$ TF_VAR_environment=staging terraform plan -no-color | grep -E "bucket_prefix"
      + bucket_prefix               = "student-project-dev-"

$ terraform apply -no-color -auto-approve -var environment=prod | grep -E "Creat|Apply"
aws_s3_bucket.demo: Creating...
aws_s3_bucket.demo: Creation complete after 0s [id=student-project-prod-fe199af9de0cbfea9f2be6420e]
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

The `TF_VAR_environment=staging` line is the one that surprised me: I set `staging` and got `dev`. Environment variables are the **lowest**-priority source after defaults, and `terraform.tfvars` (loaded automatically) beats them. The order, lowest to highest:

```
default in variable block < TF_VAR_* env var < terraform.tfvars < *.auto.tfvars < -var / -var-file on the command line
```

So in CI, if a `terraform.tfvars` is sitting in the folder, `TF_VAR_` values from your pipeline secrets will be silently ignored for any variable it sets. `-var` always wins. Also, `terraform.tfvars` is in `.gitignore` and only the `.example` is committed, because real tfvars files tend to end up holding secrets.

📸 `screenshots/03-variables-precedence.png`

---

## 6. Outputs (`06-outputs`)

```bash
$ terraform apply -no-color -auto-approve | sed -n "/Apply complete/,$p"
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

bucket_arn = "arn:aws:s3:::session18-output-9b2f521f361e0fb4928e440992"
bucket_id = "session18-output-9b2f521f361e0fb4928e440992"
bucket_region = "ap-south-1"

$ terraform output -json
{
  "bucket_arn": {
    "sensitive": false,
    "type": "string",
    "value": "arn:aws:s3:::session18-output-9b2f521f361e0fb4928e440992"
  },
  "bucket_id": {
    "sensitive": false,
    "type": "string",
    "value": "session18-output-9b2f521f361e0fb4928e440992"
  },
  "bucket_region": {
    "sensitive": false,
    "type": "string",
    "value": "ap-south-1"
  }
}

$ echo "bucket is: $(terraform output -raw bucket_id)"
bucket is: session18-output-9b2f521f361e0fb4928e440992
```

Outputs are how the generated values get out of Terraform. `-json` is for other tools (a pipeline step, another script), `-raw` gives a bare string without quotes for shell substitution, which is what I used with the AWS CLI throughout. Plain `terraform output bucket_id` would include the quotes and break the command.

📸 `screenshots/04-outputs-and-state.png`

---

## 7. State (`09-state`)

```bash
$ terraform state list
aws_s3_bucket.state_demo

$ terraform state show aws_s3_bucket.state_demo | head -12
# aws_s3_bucket.state_demo:
resource "aws_s3_bucket" "state_demo" {
    acceleration_status         = null
    arn                         = "arn:aws:s3:::session18-state-1ffbba64e5a5c9d9136d8f299a"
    bucket                      = "session18-state-1ffbba64e5a5c9d9136d8f299a"
    ...

$ ls -la terraform.tfstate* && python3 -c "...print version, serial, resources..."
-rwxrwxrwx 1 pratyush_mishra pratyush_mishra 2748 Oct  7 17:06 terraform.tfstate
version: 4 terraform: 1.16.4 serial: 2
managed aws_s3_bucket state_demo session18-state-1ffbba64e5a5c9d9136d8f299a
```

The state file is the mapping between `aws_s3_bucket.state_demo` in my code and the real bucket `session18-state-1ffb...`. Without it Terraform has no idea that bucket is "its" bucket. `serial` goes up on every write so stale copies can be detected.

### Drift: deleting the bucket behind Terraform's back

```bash
$ terraform plan -no-color | tail -2
Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.

$ aws --endpoint-url http://localhost:5000 s3 rb s3://$(terraform output -raw bucket_id)
remove_bucket: session18-state-1ffbba64e5a5c9d9136d8f299a

$ terraform plan -no-color | grep -E "#|Plan:"
  # aws_s3_bucket.state_demo has been deleted
        # (15 unchanged attributes hidden)
        # (2 unchanged blocks hidden)
  # aws_s3_bucket.state_demo will be created
Plan: 1 to add, 0 to change, 0 to destroy.

$ terraform apply -no-color -auto-approve | grep -E "Refresh|Creat|Apply"
aws_s3_bucket.state_demo: Refreshing state... [id=session18-state-1ffbba64e5a5c9d9136d8f299a]
aws_s3_bucket.state_demo: Creating...
aws_s3_bucket.state_demo: Creation complete after 0s [id=session18-state-c3b7b2ad591fdc0c1d667640a2]
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

$ terraform state list && grep -o "\"serial\": [0-9]*" terraform.tfstate
aws_s3_bucket.state_demo
"serial": 6
```

Every plan starts with a refresh: Terraform reads the real object for each resource in state and compares. It noticed the bucket was gone ("has been deleted") and planned to create it again. Note the new bucket has a *different* name (`...c3b7b2...`), because `bucket_prefix` generates a fresh suffix. Anything that had the old name hard-coded would now be broken, which is a reason to pass names around through outputs.

Why state is sensitive and is never committed (`*.tfstate` is in `.gitignore`): it holds every attribute of every resource in plain text, including things like database passwords. On a team it lives in a **remote backend** (S3 with DynamoDB / S3 native locking, or Terraform Cloud) so there is one copy, it is encrypted, and two people cannot apply at the same time.

📸 `screenshots/05-state-drift.png`

---

## 8. Destroy (`08-destroy`)

```bash
$ terraform state list
aws_s3_bucket.destroy_demo

$ terraform plan -destroy -no-color | grep -E "#|Plan:"
  # aws_s3_bucket.destroy_demo will be destroyed
        # (3 unchanged attributes hidden)
            # (1 unchanged attribute hidden)
Plan: 0 to add, 0 to change, 1 to destroy.

$ terraform destroy -no-color -auto-approve | grep -E "Destroy|Refresh"
aws_s3_bucket.destroy_demo: Refreshing state... [id=session18-destroy-e05c587b9552b579d4cdb5d4b4]
          - "Name" = "Session 18 Destroy Demo"
          - "Name" = "Session 18 Destroy Demo"
aws_s3_bucket.destroy_demo: Destroying... [id=session18-destroy-e05c587b9552b579d4cdb5d4b4]
Destroy complete! Resources: 1 destroyed.

$ terraform state list | wc -l && aws --endpoint-url http://localhost:5000 s3 ls | grep -c session18-destroy
0
0
```

`plan -destroy` is the dry run of `destroy`; always worth reading before deleting things. Destroy only removes what is in *this* state file, nothing else in the account.

### Destroy fails on a non-empty bucket

Then I applied it again, put a file in the bucket, and tried to destroy:

```bash
$ aws --endpoint-url http://localhost:5000 s3 cp /tmp/hello.txt s3://session18-destroy-8c536e50088a44421165a04171/hello.txt --only-show-errors && aws --endpoint-url http://localhost:5000 s3 ls s3://session18-destroy-8c536e50088a44421165a04171/
2026-10-07 17:11:11         22 hello.txt

$ terraform destroy -no-color -auto-approve 2>&1 | grep -vE '^ +[-~+ ] |^ +[}#]|^$' | tail -12
aws_s3_bucket.destroy_demo: Refreshing state... [id=session18-destroy-8c536e50088a44421165a04171]
Terraform used the selected providers to generate the following execution
plan. Resource actions are indicated with the following symbols:
Terraform will perform the following actions:
Plan: 0 to add, 0 to change, 1 to destroy.
aws_s3_bucket.destroy_demo: Destroying... [id=session18-destroy-8c536e50088a44421165a04171]
Error: deleting S3 Bucket (session18-destroy-8c536e50088a44421165a04171): operation error S3: DeleteBucket, https response error StatusCode: 409, RequestID: ..., api error BucketNotEmpty: The bucket you tried to delete is not empty

$ aws --endpoint-url http://localhost:5000 s3 rm s3://session18-destroy-8c536e50088a44421165a04171 --recursive && terraform destroy -no-color -auto-approve | grep -E 'Destroy complete'
delete: s3://session18-destroy-8c536e50088a44421165a04171/hello.txt
Destroy complete! Resources: 1 destroyed.
```

S3 refuses to delete a bucket that has objects in it (409 `BucketNotEmpty`), and Terraform passes that straight through. That is a good default; it stops `terraform destroy` from silently wiping data. The way round it is either emptying the bucket first (above) or `force_destroy = true`, which the s3-demo uses (next section).

📸 `screenshots/06-destroy-force-destroy.png`

---

## 9. Mini project: `terraform-s3-demo`

This is the project layout you would actually use, one file per concern: `terraform.tf` (version pins), `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf`, plus a committed `.terraform.lock.hcl`. It creates a fixed-name bucket `yatri1107` with `force_destroy = true` and four tags.

```bash
$ ls && terraform fmt -check -diff; echo "fmt exit code: $?"
README.md
main.tf
moto_override.tf
outputs.tf
providers.tf
terraform.tf
variables.tf
fmt exit code: 0

$ terraform validate -no-color
Success! The configuration is valid.

$ terraform plan -no-color -out=s3demo.tfplan | grep -E "will be created|bucket  |force_destroy|Plan:"
  # aws_s3_bucket.devops553 will be created
      + bucket                      = "yatri1107"
      + force_destroy               = true
Plan: 1 to add, 0 to change, 0 to destroy.

$ terraform apply -no-color s3demo.tfplan | sed -n "/Creat/,$p"
aws_s3_bucket.devops553: Creating...
aws_s3_bucket.devops553: Creation complete after 0s [id=yatri1107]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

bucket_arn = "arn:aws:s3:::yatri1107"
bucket_name = "yatri1107"
bucket_region = "ap-south-1"
```

Then the same test as section 8, a file in the bucket and a destroy:

```bash
$ echo "hello from session 18" > /tmp/hello.txt && aws --endpoint-url http://localhost:5000 s3 cp /tmp/hello.txt s3://$(terraform output -raw bucket_name)/hello.txt && aws --endpoint-url http://localhost:5000 s3 ls s3://$(terraform output -raw bucket_name)/
upload: ../../../../../../../tmp/hello.txt to s3://yatri1107/hello.txt
2026-10-07 17:09:46         22 hello.txt

$ aws --endpoint-url http://localhost:5000 s3api get-bucket-tagging --bucket $(terraform output -raw bucket_name) --output text
TAGSET	Environment	dev
TAGSET	ManagedBy	Terraform
TAGSET	Name	yatri1107
TAGSET	Project	Session18

$ terraform destroy -no-color -auto-approve | grep -E "Destroy|destroyed"
  # aws_s3_bucket.devops553 will be destroyed
aws_s3_bucket.devops553: Destroying... [id=yatri1107]
Destroy complete! Resources: 1 destroyed.

$ terraform state list | wc -l; aws --endpoint-url http://localhost:5000 s3 ls | grep yatri1107 || echo "bucket yatri1107 is gone"
0
bucket yatri1107 is gone
```

With `force_destroy = true` the provider deletes every object first, so the destroy goes through with `hello.txt` still inside. Handy for a lab; for a bucket with real data it is exactly the setting you do not want.

Two notes on this project: the outputs use `type = string`, which `validate` accepts on Terraform 1.16; and the bucket name is fixed, and S3 bucket names are global across all AWS accounts, so on real AWS `yatri1107` only works for whoever claimed it first. That is why the lesson folders use `bucket_prefix` instead.

📸 `screenshots/06-destroy-force-destroy.png` (same shot as section 8)

Everything was destroyed at the end; no buckets from this session are left in moto.

---

## File index

| Path | What it is |
| --- | --- |
| `01-iac-basics/` | Smallest config: one bucket, one output |
| `02-terraform-architecture/` | Core vs provider vs state |
| `03-providers/` | Provider block driven by `var.aws_region` |
| `04-resources/` | Resource syntax and addressing |
| `05-variables/` | Variables, `terraform.tfvars.example` |
| `06-outputs/` | Outputs: id, ARN, region |
| `07-init-plan-apply/` | Full lifecycle |
| `08-destroy/` | Destroy |
| `09-state/` | State |
| `terraform-s3-demo/` | Mini project split into `terraform.tf`, `providers.tf`, `variables.tf`, `main.tf`, `outputs.tf` |
| `moto/moto_override.tf` | **Mine**: provider override to run any lab against moto instead of AWS |
| `screenshots/` | Terminal captures |

## Resources

- Instructor's original top-level `Readme.md` (install links for Terraform and the AWS CLI): <https://github.com/Nency-Ravaliya/devops-heros/blob/main/session18-terraform-iac/Readme.md>
- <https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli>
- <https://developer.hashicorp.com/terraform/language/files/override>
- <https://developer.hashicorp.com/terraform/language/values/variables#variable-definition-precedence>
- <https://docs.getmoto.org/en/latest/docs/server_mode.html>
