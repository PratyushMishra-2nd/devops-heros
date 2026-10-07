# Session 19: Cloud Basics and AWS Networking with Terraform

**Pratyush Mishra · Roll No. 10486**

Went over the cloud basics (service models, regions and AZs, VPCs and subnets, route tables and internet gateways, security groups), then built a full VPC with Terraform. The VPC lab (`06-terraform-vpc`) **ran on real AWS**, in `ap-northeast-3` (Osaka), using the temporary credentials the instructor handed out in class, which were only valid for about 10 minutes. I do not have an AWS account of my own, so the other two labs (`07-terraform-workflow` and `08-mini-project`) ran for real against **moto**, a local AWS emulator, the same way as Session 18.

**Setup:** Ubuntu 26.04 on WSL2, Terraform v1.16.4, hashicorp/aws provider 6.x, AWS CLI v2. Real AWS for section 6; moto 5.2.3 on `localhost:5000` for sections 7 and 8.

---

## 1. Cloud service models

The question is just how much of the stack you run yourself.

| Model | I manage | Provider manages | Example |
| --- | --- | --- | --- |
| **IaaS** | OS, runtime, app, data | Hardware, network, virtualisation | EC2, a VPC |
| **PaaS** | App code and data | Everything under it, incl. OS patching and scaling | Elastic Beanstalk, Heroku |
| **SaaS** | Just my data and settings | The whole application | Gmail |

Everything in this session is IaaS: I am building the network myself, which is the most control and the most responsibility. The further right you go, the less you can break and the less you can customise.

## 2. Regions and Availability Zones

A **region** is a geographic area (`ap-south-1` Mumbai, `ap-northeast-3` Osaka) and is fully independent of other regions; resources and IDs do not cross over. An **AZ** is one or more separate data centres inside a region with its own power and networking (`ap-northeast-3a`, `-3b`, ...). You spread across AZs so one data centre going down does not take you out, and you pick the region for latency, data residency and price.

In Terraform the region is set on the provider, and an AZ name is just the region plus a letter, which is exactly how the labs build it: `availability_zone = "${var.aws_region}a"`.

## 3. VPC and subnets

A **VPC** is my own private network inside AWS with an address range I choose, e.g. `10.0.0.0/16`. A **subnet** is a slice of that range that lives in exactly **one** AZ, e.g. `10.0.1.0/24`.

CIDR quick maths: the number after the slash is how many bits are fixed, so `/16` leaves 16 bits = 65,536 addresses and `/24` leaves 8 bits = 256. AWS keeps 5 addresses in every subnet (network, router, DNS, reserved, broadcast), so a `/24` gives 251 usable IPs.

"Public" and "private" are not a setting on the subnet. A subnet is public only because of the next section.

## 4. Route tables and the internet gateway

Every subnet is associated with a **route table** that says where traffic for each destination goes. Every route table has the implicit `10.0.0.0/16 → local` route so everything inside the VPC can talk to itself. An **internet gateway (IGW)** is attached to the VPC and is the door to the internet.

A subnet is **public** when its route table has `0.0.0.0/0 → igw-...`. `0.0.0.0/0` means "any address not matched by a more specific route", i.e. the whole internet. Without that route the IGW is attached but nothing uses it. Instances also need a public IP, which is what `map_public_ip_on_launch = true` on the subnet gives them.

## 5. Security groups

A **security group** is a firewall on the instance's network interface. Rules are allow-only (no deny rules), and it is **stateful**: if inbound traffic on port 80 is allowed, the reply goes back out automatically without an outbound rule.

| | Question it answers |
| --- | --- |
| Route table | *Where* can this traffic go? |
| Security group | Is this traffic *allowed* to reach this instance? |

Both have to say yes. The lab's group allows 80 and 443 from anywhere and all outbound. Port 22 from `0.0.0.0/0` is the classic mistake; SSH should be limited to your own IP or replaced with SSM Session Manager.

---

## 6. `06-terraform-vpc` on real AWS (ap-northeast-3)

This lab builds all of sections 3–5 in one go:

```
                 Internet
                     │
            aws_internet_gateway.main
                     │
   aws_vpc.main  10.0.0.0/16
   ┌──────────────────────────────────────────────────────┐
   │ aws_subnet.public  10.0.1.0/24  (ap-northeast-3a)    │
   │   └─ aws_route_table_association.public              │
   │        └─ aws_route_table.public: 0.0.0.0/0 → IGW    │
   │ aws_security_group.web: in 80, 443 / out all         │
   └──────────────────────────────────────────────────────┘
```

The instructor gave us temporary AWS credentials for the class account that expired after about 10 minutes, so this part had to be done quickly and I took screenshots instead of capture logs. Before running it I changed two things: the `Name` tags and the security group name from `session19-*` to `pratyush-*` (so my resources could be told apart from everyone else's in the shared account), and the default region in `variables.tf` from `ap-south-1` to `ap-northeast-3`, the region configured with those credentials. Those edits are the uncommitted changes in `06-terraform-vpc/`.

### Apply

📸 `screenshots/01-aws-terraform-apply.png`. Transcribed from the screenshot:

```bash
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes

aws_vpc.main: Creating...
aws_vpc.main: Creation complete after 3s [id=vpc-0f3a805c739a48ddd]
aws_internet_gateway.main: Creating...
aws_subnet.public: Creating...
aws_security_group.web: Creating...
aws_internet_gateway.main: Creation complete after 1s [id=igw-05fa51a25d58c77e3]
aws_route_table.public: Creating...
aws_route_table.public: Creation complete after 2s [id=rtb-0ee95679e4cd947d9]
aws_security_group.web: Creation complete after 3s [id=sg-0071f96e879c49349]
aws_subnet.public: Still creating... [00m10s elapsed]
aws_subnet.public: Creation complete after 12s [id=subnet-0db0c90d295c43ccb]
aws_route_table_association.public: Creating...
aws_route_table_association.public: Creation complete after 0s [id=rtbassoc-0d0bd1c203890f66a]

Apply complete! Resources: 6 added, 0 changed, 0 destroyed.

Outputs:

security_group_id = "sg-0071f96e879c49349"
subnet_id = "subnet-0db0c90d295c43ccb"
vpc_cidr = "10.0.0.0/16"
vpc_id = "vpc-0f3a805c739a48ddd"
```

The order shows Terraform's dependency graph doing its job. The VPC comes first because everything references `aws_vpc.main.id`. Then the IGW, subnet and security group start **at the same time**, because none of them depends on the others. The route table waits for the IGW (its route points at `aws_internet_gateway.main.id`), and the association waits for both the subnet and the route table. I never wrote that order down anywhere; Terraform worked it out from the references.

The subnet was the slow one at 12s. With `map_public_ip_on_launch = true` the provider creates the subnet and then waits for that attribute to be set, which takes a few extra seconds. It did the same against moto (section 8), 10s there.

### Which credentials, and what was created

📸 `screenshots/02-aws-configure-and-show.png`:

```bash
$ aws configure list
NAME       : VALUE                    : TYPE             : LOCATION
profile    : <not set>                : None             : None
access_key : ****************NJNR     : shared-credentials-file :
secret_key : ****************dxgi     : shared-credentials-file :
region     : ap-northeast-3           : config-file      : ~/.aws/config

$ terraform show
# aws_internet_gateway.main:
resource "aws_internet_gateway" "main" {
    arn      = "arn:aws:ec2:ap-northeast-3:<account-id>:internet-gateway/igw-05fa51a25d58c77e3"
    id       = "igw-05fa51a25d58c77e3"
    owner_id = "<account-id>"
    region   = "ap-northeast-3"
    tags     = {
        "ManagedBy" = "Terraform"
        "Name"      = "pratyush-igw"
        "Session"   = "19"
    }
    tags_all = {
        "ManagedBy" = "Terraform"
        "Name"      = "pratyush-igw"
        "Session"   = "19"
    }
    vpc_id   = "vpc-0f3a805c739a48ddd"
}

# aws_route_table.public:
resource "aws_route_table" "public" {
    arn              = "arn:aws:ec2:ap-northeast-3:<account-id>:route-table/rtb-0ee95679e4cd947d9"
    id               = "rtb-0ee95679e4cd947d9"
    owner_id         = "<account-id>"
    propagating_vgws = []
    region           = "ap-northeast-3"
    route            = [
        {
            carrier_gateway_id         = null
            cidr_block                 = "0.0.0.0/0"
            ...
            gateway_id                 = "igw-05fa51a25d58c77e3"
            ...
        },
...
```

(The account ID is visible in the screenshot; I have replaced it with `<account-id>` here rather than repeat it.)

`aws configure list` shows where the CLI and Terraform got their credentials: a key ending `NJNR` from the shared credentials file and the region from `~/.aws/config`. Terraform's AWS provider reads the same files, which is why `versions.tf` only has `region = var.aws_region` and no keys. Keys never go in `.tf` files.

`terraform show` confirms the wiring: the IGW belongs to `vpc-0f3a805c739a48ddd`, and the public route table sends `0.0.0.0/0` to that IGW (`gateway_id = "igw-05fa51a25d58c77e3"`), which is what makes the subnet public.

### Outputs and state

📸 `screenshots/03-aws-outputs-state-list.png`, the end of `terraform show` (the VPC) and then `terraform state list`:

```bash
    id                                   = "vpc-0f3a805c739a48ddd"
    instance_tenancy                     = "default"
    ipv6_association_id                  = null
    ipv6_cidr_block                      = null
    ipv6_cidr_block_network_border_group = null
    ipv6_ipam_pool_id                    = null
    ipv6_netmask_length                  = 0
    main_route_table_id                  = "rtb-02964a8693a81688d"
    owner_id                             = "<account-id>"
    region                               = "ap-northeast-3"
    tags                                 = {
        "ManagedBy" = "Terraform"
        "Name"      = "pratyush-vpc"
        "Session"   = "19"
    }
    ...
}

Outputs:

security_group_id = "sg-0071f96e879c49349"
subnet_id = "subnet-0db0c90d295c43ccb"
vpc_cidr = "10.0.0.0/16"
vpc_id = "vpc-0f3a805c739a48ddd"

$ terraform state list
aws_internet_gateway.main
aws_route_table.public
aws_route_table_association.public
aws_security_group.web
aws_subnet.public
aws_vpc.main
```

Note the VPC's `main_route_table_id` is `rtb-02964a8693a81688d`, a *different* route table from the one I created (`rtb-0ee95679e4cd947d9`). Every VPC automatically gets a "main" route table with only the local route, and any subnet not explicitly associated with something else uses it. That is why the lab needs `aws_route_table_association`: without it my subnet would sit on the main table, have no internet route, and be private despite the IGW.

### Afterwards: destroyed

I destroyed everything before the credentials ran out. The state files left in the folder show it (read-only, no AWS call needed):

```bash
$ terraform state list | wc -l
0

$ python3 -c "...print serial and resources for both state files..."
terraform.tfstate.backup serial 8 resources 6 ['aws_internet_gateway.main', 'aws_route_table.public', 'aws_route_table_association.public', 'aws_security_group.web', 'aws_subnet.public', 'aws_vpc.main']
terraform.tfstate serial 15 resources 0 []

$ ls -la --time-style=+%H:%M terraform.tfstate*
-rwxrwxrwx 1 pratyush_mishra pratyush_mishra   182 12:53 terraform.tfstate
-rwxrwxrwx 1 pratyush_mishra pratyush_mishra 12233 12:53 terraform.tfstate.backup
```

The backup (written just before the last change) still has the 6 resources; the current state has none. 12:53 UTC is 18:23 IST, a minute after the last screenshot (18:22). Neither file is committed (`*.tfstate*` is in `.gitignore`), and with real AWS that matters, because the state contains the account ID in every ARN.

📸 `screenshots/04-vpc-state-and-workflow.png` (top part)

---

## 7. `07-terraform-workflow`, against moto

From here on there were no AWS credentials, so I used the same approach as Session 18: `moto/moto_override.tf` is a Terraform override file that gets merged into the lab's `provider "aws"` block and points it at moto on `localhost:5000` with fake credentials. This version also routes `ec2` there, for the VPC resources in section 8. I copy it in, run the lab, and delete it, so the lab files stay as they are.

The workflow lesson is the standard order of commands, and the order is the point:

```bash
$ cp ../moto/moto_override.tf . && terraform init -no-color | grep -E "Installing|Installed|Reusing|successfully"
- Reusing previous version of hashicorp/aws from the dependency lock file
Terraform has been successfully initialized!

$ terraform fmt -check -recursive; echo "fmt exit code: $?" && terraform validate -no-color
fmt exit code: 0
Success! The configuration is valid.

$ terraform plan -no-color -out=workflow.tfplan | grep -E "#|Plan:|Saved"
  # aws_s3_bucket.workflow_demo will be created
Plan: 1 to add, 0 to change, 0 to destroy.
Saved the plan to: workflow.tfplan

$ terraform apply -no-color workflow.tfplan | grep -E "Creat|Apply|bucket_name"
aws_s3_bucket.workflow_demo: Creating...
aws_s3_bucket.workflow_demo: Creation complete after 0s [id=session19-workflow-283ed42c53b75d61946917c231]
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
bucket_name = "session19-workflow-283ed42c53b75d61946917c231"

$ terraform output && terraform state list
bucket_name = "session19-workflow-283ed42c53b75d61946917c231"
aws_s3_bucket.workflow_demo

$ terraform plan -destroy -no-color | grep -E "#|Plan:"
  # aws_s3_bucket.workflow_demo will be destroyed
        # (3 unchanged attributes hidden)
            # (1 unchanged attribute hidden)
Plan: 0 to add, 0 to change, 1 to destroy.

$ terraform destroy -no-color -auto-approve | grep -E "Destroying|Destroy complete"
aws_s3_bucket.workflow_demo: Destroying... [id=session19-workflow-283ed42c53b75d61946917c231]
Destroy complete! Resources: 1 destroyed.
```

`init` → `fmt` → `validate` are free and offline, so they go first and fail fast. `plan -out` saves the exact set of changes and `apply <planfile>` applies only that, with no second prompt, so what was reviewed is what runs. `plan -destroy` is the review step before a `destroy`. ("Reusing previous version" is because I had already run `init` in this folder once before capturing.)

📸 `screenshots/04-vpc-state-and-workflow.png`

---

## 8. `08-mini-project`: the same VPC, against moto

The mini project is the section 6 VPC again with its own names (`session19-mini-*`) and a `10.20.0.0/16` range, in `ap-south-1`.

### `fmt` caught something

```bash
$ terraform fmt -check -diff; echo "fmt exit code: $?"
main.tf
--- old/main.tf
+++ new/main.tf
@@ -38,7 +38,7 @@

   route {
     cidr_block = "0.0.0.0/0"
-    gateway_id  = aws_internet_gateway.main.id
+    gateway_id = aws_internet_gateway.main.id
   }

   tags = {
fmt exit code: 3

$ terraform fmt && terraform fmt -check && echo "fmt: clean" && terraform validate -no-color
main.tf
fmt: clean
Success! The configuration is valid.
```

One extra space before `=` in the route block. It changes nothing about what gets built, but `fmt -check` exits non-zero (3), so in a pipeline with a format check this file would fail the build. I let `terraform fmt` fix it; that one-space change is the only edit to `08-mini-project/main.tf`.

### Plan and apply

```bash
$ terraform plan -no-color -out=mini.tfplan | grep -E "will be created|Plan:"
  # aws_internet_gateway.main will be created
  # aws_route_table.public will be created
  # aws_route_table_association.public will be created
  # aws_security_group.web will be created
  # aws_subnet.public will be created
  # aws_vpc.main will be created
Plan: 6 to add, 0 to change, 0 to destroy.

$ terraform apply -no-color mini.tfplan | grep -E "Creation complete|Apply complete" ; terraform output
aws_vpc.main: Creation complete after 1s [id=vpc-81a8173118f8a4c9c]
aws_internet_gateway.main: Creation complete after 0s [id=igw-fb90dae17777a61bf]
aws_route_table.public: Creation complete after 0s [id=rtb-72fc553f8837312f7]
aws_security_group.web: Creation complete after 0s [id=sg-61169c8b760498127]
aws_subnet.public: Creation complete after 10s [id=subnet-81e2749ae79e0c4a5]
aws_route_table_association.public: Creation complete after 0s [id=rtbassoc-a40f72bf92ee6f0ee]
Apply complete! Resources: 6 added, 0 changed, 0 destroyed.
security_group_id = "sg-61169c8b760498127"
subnet_id = "subnet-81e2749ae79e0c4a5"
vpc_cidr = "10.20.0.0/16"
vpc_id = "vpc-81a8173118f8a4c9c"
```

Same 6 resources, same creation order and the same slow subnet as on real AWS.

📸 `screenshots/05-mini-project-fmt-apply.png`

### Checking it with the AWS CLI

The `06-terraform-vpc` README has a set of `aws ec2 describe-*` commands for checking the network outside Terraform. Same commands, pointed at moto:

```bash
$ terraform state list
aws_internet_gateway.main
aws_route_table.public
aws_route_table_association.public
aws_security_group.web
aws_subnet.public
aws_vpc.main

$ aws --endpoint-url http://localhost:5000 --output table ec2 describe-vpcs --filters Name=tag:Name,Values=session19-mini-vpc --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,State:State}'
--------------------------------------------------------
|                     DescribeVpcs                     |
+---------------+------------+-------------------------+
|     Cidr      |   State    |          VpcId          |
+---------------+------------+-------------------------+
|  10.20.0.0/16 |  available |  vpc-81a8173118f8a4c9c  |
+---------------+------------+-------------------------+

$ aws ... ec2 describe-subnets --filters Name=tag:Name,Values=session19-mini-public-subnet --query 'Subnets[].{SubnetId:SubnetId,Cidr:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}'
-------------------------------------------------------------------------
|                            DescribeSubnets                            |
+-------------+---------------+-----------+-----------------------------+
|     AZ      |     Cidr      | PublicIP  |          SubnetId           |
+-------------+---------------+-----------+-----------------------------+
|  ap-south-1a|  10.20.1.0/24 |  True     |  subnet-81e2749ae79e0c4a5   |
+-------------+---------------+-----------+-----------------------------+

$ aws ... ec2 describe-route-tables --filters Name=tag:Name,Values=session19-mini-public-rt --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,Target:GatewayId}'
-------------------------------------------
|           DescribeRouteTables           |
+---------------+-------------------------+
|     Dest      |         Target          |
+---------------+-------------------------+
|  10.20.0.0/16 |  local                  |
|  0.0.0.0/0    |  igw-fb90dae17777a61bf  |
+---------------+-------------------------+

$ aws ... ec2 describe-security-groups --filters Name=group-name,Values=session19-mini-web-sg --query 'SecurityGroups[].IpPermissions[].{From:FromPort,To:ToPort,Proto:IpProtocol,Cidr:IpRanges[0].CidrIp}'
---------------------------------------
|       DescribeSecurityGroups        |
+------------+-------+--------+-------+
|    Cidr    | From  | Proto  |  To   |
+------------+-------+--------+-------+
|  0.0.0.0/0 |  80   |  tcp   |  80   |
|  0.0.0.0/0 |  443  |  tcp   |  443  |
+------------+-------+--------+-------+

$ terraform plan -no-color -detailed-exitcode | tail -2; echo "plan exit code: ${PIPESTATUS[0]}"
Terraform has compared your real infrastructure against your configuration
and found no differences, so no changes are needed.
plan exit code: 0
```

Every concept from sections 3–5 shows up in one of these tables: the `/16` VPC, the `/24` subnet in one AZ with public IPs on launch, the route table with the implicit `local` route plus `0.0.0.0/0 → IGW` (which is the whole definition of "public subnet"), and the security group allowing only 80 and 443 in. The final plan with exit code 0 confirms the real infrastructure matches the code exactly.

### Destroy

```bash
$ terraform destroy -no-color -auto-approve | grep -E "Destruction complete|Destroy complete"
aws_route_table_association.public: Destruction complete after 0s
aws_subnet.public: Destruction complete after 0s
aws_security_group.web: Destruction complete after 0s
aws_route_table.public: Destruction complete after 1s
aws_internet_gateway.main: Destruction complete after 0s
aws_vpc.main: Destruction complete after 0s
Destroy complete! Resources: 6 destroyed.

$ terraform state list | wc -l && aws --endpoint-url http://localhost:5000 ec2 describe-vpcs --filters Name=tag:Name,Values=session19-mini-vpc --query "length(Vpcs)"
0
0
```

Destroy runs the dependency graph backwards: the association goes first, the VPC last, because you cannot delete a VPC that still has a subnet or an attached gateway in it.

📸 `screenshots/06-mini-project-verify-destroy.png`

---

## File index

| Path | What it is |
| --- | --- |
| `01-cloud-service-models/` | IaaS / PaaS / SaaS |
| `02-regions-and-availability-zones/` | Regions and AZs |
| `03-vpc-and-subnets/` | VPCs, subnets, CIDR |
| `04-route-tables-and-internet-gateway/` | Route tables, IGW, what makes a subnet public |
| `05-security-groups/` | Security groups, stateful rules |
| `06-terraform-vpc/` | The VPC lab. Ran on **real AWS** (ap-northeast-3) with the instructor's temporary credentials; names changed to `pratyush-*` |
| `07-terraform-workflow/` | init → fmt → validate → plan → apply → output → destroy (ran on moto) |
| `08-mini-project/` | VPC mini project (ran on moto; `terraform fmt` fixed one line) |
| `moto/moto_override.tf` | **Mine**: provider override that points the labs at moto instead of AWS |
| `screenshots/` | 01–03 real AWS run, 04–06 terminal captures |

## Resources

- <https://github.com/Nency-Ravaliya/devops-heros/tree/main/session19-cloud-terraform>
- <https://docs.aws.amazon.com/vpc/latest/userguide/how-it-works.html>
- <https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html>
- <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc>
- <https://docs.getmoto.org/en/latest/docs/server_mode.html>
