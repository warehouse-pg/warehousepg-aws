# WarehousePG on AWS

## Overview
This repo contains two different CloudFormation templates: *warehousepg.yaml* and *warehousepg_classic.yaml". The classic template uses EBS storage and database mirroring while the newer template uses S3 and EFS to eliminate the need for mirroring.

## Optional: Steps to modify and upload deployment scripts
Note: If you are using `us-east-1` in `EDB-SalesEngineering-SE-EMA`, you should already have access to the bucket `s3://fcto-s3-01` for the Classic template and `s3://fcto-s3-02` for the new template. This is where the scripts have already been copied so you can skip this step.

1. Create a bucket in the region you are wishing to deploy.
2. Log into AWS via Okta and click on Access Keys.
![Access Keys](/images/access_keys.png)
3. Open a terminal and run `aws configure`.
4. On the Access Keys page, copy and paste the access key id, secret access key, and the session token in the terminal window. These are temporary credentials so these will expire after a few hours. Specify the region and you can use any format you want for the output.
![Credentials](/images/credentials.png)
![AWS Configure](/images/aws_configure.png)
5. Change to the UserData directory, change the bucket location to your new bucket, run `./upload.sh`.

## VPC
If you are using `us-east-1` in `EDB-SalesEngineering-SE-EMA`, you can use the VPC `fcto-vpc` else, you need to create or use an existing VPC in your account and region.

![Private](/images/private.png)
You need at a minimum a private subnet configured with a NAT Gateway so that commands like `dnf` and `yum` work. If you only use a private network, you need to specify `FALSE` when setting `InternetAccess`.

![Public](/images/public.png)
Ideally, you also have a public subnet configured. It needs an Internet Gateway so that you can access the coordinator node. Only port 22 will be open to the CIDR range specified with `SSHCIDR`. 

Note: make sure the subnets are in the VPC you choose as parameters. AWS does not have dependent parameters so it will show you a list of all subnets in your region.

### CloudFormation Stack
![Architecture](images/warehousepg_architecture_detailed.png)
Deploys a WarehousePG cluster on AWS into an existing VPC using AWS CloudFormation leveraging local SSD for caching, S3Files for data storage, and EFS for database files other than data.

#### Overview 
* No segment mirroring
* Data stored in S3: 3+ Availability Zones, 11 9's of availability
* Can sustain an AZ failure by deploying new cluster in another AZ in the same Region
* Over 30% less expensive than Classic Template
* Slower initial queries and data loading
* Same query performance as Classic Template (1 and 5 concurrent users and before EBS bursting is exhausted)
* Local NVMe caching so consistent performance even with a busy cluster (no bursting exhaustion)

#### Deployment
1. In the AWS Console, go to CloudFormation and create a new Stack. Pick "upload a template file" and navigate to the file `warehousepg.yaml` in this repo.
![CFT1](/images/cft1.png)
2. Fill out the parameters
- `Stack name`: this is mandatory.
- `DeploymentBucket`: name of the bucket where your deployment scripts are.
- `AccessToken`: the EDB access token for downloading EDB software.
- `DatabaseName`: name of the default database name (PGDATABASE) created
- `InternetAccess`: if true, the coordinator node will have access to the Internet.
- `SSHCIDER`: make this as restrive as possible. 0.0.0.0/0 will be removed automatically in EDB's accounts. Only used when InternetAccess is true and only applies to the coordinator node.
- `VPC`: existing VPC to deploy in.
- `PrivateSubnet`: Private subnet where the compute nodes will be deployed.
- `PublicSubnet`: Public subnet where the coordinator node will be deployed. Be sure to deploy both subnets in the same AZ! You can also specify the existing Private subnet here if you don't wish to allow Internet access to the coordinator node.
- `NodeType`: specifies the IntancesType in AWS. This needs to be an instance type with a local SSD drive.
- `SegmentNodeCount`: 0 to 48 nodes in increments of 2 nodes can be deployed. Setting 0 means it will be a single node and the coordinator and segments will reside there. Setting 2 or larger will enable mirroring and deploy on all nodes.
- `AMI`: The existing AWS AMI ID that is valid for your region. The default is the AMI for Rocky Linux 9 and the scripts have been written for this operating system. Be sure you are subscribed to the AMI before launching the Stack and ideally, use Rocky Linux 9 as that has been tested.
- `KeyPair`: specifies the existing KeyPair for ssh access to the coordinator node.
- `TimeZone`: sets the TZ on all nodes.

### CloudFormation Classic Stack
![Architecture](/images/warehousepg_classic_architecture.png)
Deploys a WarehousePG cluster on AWS into an existing VPC using AWS CloudFormation leveraging EBS storage and databaes mirroring.

#### Overview 
* Segment mirroring
* Data stored in EBS: 1 Availability Zone, 99.9% of availability
* Can NOT sustain an AZ failure
* Over 30% MORE expensive than new Template
* No caching so initial queries and data loading are quicker than new template
* Same query performance as new Template (1 and 5 concurrent users and before EBS bursting is exhausted)
* EBS bursting can be exhausted with busy cluster and performance slows down

#### Deployment
1. In the AWS Console, go to CloudFormation and create a new Stack. Pick "upload a template file" and navigate to the file `warehousepg_classic.yaml` in this repo.
![CFT1](/images/cft1.png)
2. Fill out the parameters
- `Stack name`: this is mandatory.
- `S3Bucket`: name of the bucket where your deployment scripts are.
- `AccessToken`: the EDB access token for downloading EDB software.
- `AMI`: The existing AWS AMI ID that is valid for your region. The default is the AMI for Rocky Linux 9 and the scripts have been written for this operating system. Be sure you are subscribed to the AMI before launching the Stack and ideally, use Rocky Linux 9 as that has been tested.
- `DatabaseName`: name of the default database name (PGDATABASE) created
- `SegmentsPerDisk`: the number of segment processes per data volume. Typically 1:1 works best.
- `InternetAccess`: if true, the coordinator node will have access to the Internet.
- `SSHCIDER`: make this as restrive as possible. 0.0.0.0/0 will be removed automatically in EDB's accounts. Only used when InternetAccess is true and only applies to the coordinator node.
- `VPC`: existing VPC to deploy in.
- `PrivateSubnet`: Private subnet where the compute nodes will be deployed.
- `PublicSubnet`: Public subnet where the coordinator node will be deployed. Be sure to deploy both subnets in the same AZ! You can also specify the existing Private subnet here if you don't wish to allow Internet access to the coordinator node.
- `DataDisks`: the number of data volumes per compute node. 
- `DiskEncrypted`: specifies to use AWS encryption on the data volumes.
- `DiskType`: specifies the disk type. SC1 is ideal for testing and ST1 for production. For extremely busy workloads, GP3 can be used but it costs the most.
- `KeyPair`: specifies the existing KeyPair for ssh access to the coordinator node.
- `TimeZone`: sets the TZ on all nodes.
- `CoordinatorNodeType`: specifies InstanceType in AWS. Currently tested with r8i series.
- `CoordinatorDiskSize`: the data volume on the coordinator. 
- `SegmentNodeType`: specifies the IntancesType in AWS. Currently tested with r8i series.
- `SegmentDiskSize`: specifies the data volume size on each segment node. Remember you can also specify the number of data volumes per node.
- `SegmentNodeCount`: 0 to 48 nodes in increments of 2 nodes can be deployed. Setting 0 means it will be a single node and the coordinator and segments will reside there. Setting 2 or larger will enable mirroring and deploy on all nodes.

## Debugging 
1. You can specify to preserve resources in the Stack so that if it fails, the nodes will be preserved.
2. `ssh` to the coordinator node and `sudo bash`. Then `tail -f /var/log/cloud-init-output.log` to watch the progress of the deployment.
