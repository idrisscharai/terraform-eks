###############################################################################
########################## SOME VARS & DATA SOURCES ###########################
###############################################################################

variable "cluster_name" {
  default = "test-cluster"
}

provider "aws" {
  region = "eu-central-1"
}

# Search for latest Ubuntu server image
data "aws_ami" "ubuntu_latest" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*-*.*-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Search for instance type
data "aws_ec2_instance_type_offering" "ubuntu_micro" {
  filter {
    name   = "instance-type"
    values = ["t2.micro"]
  }
}

# Availability zones data source to get list of AWS Availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

###############################################################################
################################### VPC #######################################
###############################################################################

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  name   = "test-vpc"

  cidr            = "10.0.0.0/16"
  azs             = data.aws_availability_zones.available.names
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = true
  single_nat_gateway   = true

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    "k8s.io/cluster-autoscaler/enabled"         = true
    "k8s.io/cluster-autoscaler/jupyterhub"      = "owned"

  }

}

###############################################################################
###############################  CLUSTER DATA   ###############################
###############################################################################

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

###############################################################################
############################### EKS CLUSTER ###################################
###############################################################################

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = var.cluster_name
  cluster_version = "1.17"
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id
  cluster_enabled_log_types = ["audit"] #, "api", "authenticator", "controllerManager", "scheduler"]
    
  worker_groups = [
    {
      name                 = "worker-group-1"
      instance_type        = data.aws_ec2_instance_type_offering.ubuntu_micro.id
      subnets              = [module.vpc.private_subnets[0]]
      asg_desired_capacity = 1
    },
    {
      name                 = "worker-group-2"
      instance_type        = data.aws_ec2_instance_type_offering.ubuntu_micro.id
      subnets              = [module.vpc.private_subnets[1]]
      asg_desired_capacity = 1
    }
  ]
}
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  token                  = data.aws_eks_cluster_auth.cluster.token
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  load_config_file       = false
}
    
###############################################################################
############################### HELM & JHUB ###################################
###############################################################################
    
# Helm provider installs in Kubernetes cluster

provider "helm" {

  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    token                  = data.aws_eks_cluster_auth.cluster.token
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
    load_config_file       = false
  }
}

# Pulls J-hub Helm chart and uses values.yaml file

resource "helm_release" "jhub" {
  name       = "jupyterhub"
  repository = "https://jupyterhub.github.io/helm-chart/"
  chart      = "jupyterhub"

  values = [
    file("values.yaml")
  ]
}    
    
###############################################################################
############################### S3 BUCKET #####################################
###############################################################################

resource "aws_s3_bucket" "log_bucket" {
  bucket = "test-bucket-cloud-auto-acc-interns"
  acl    = "log-delivery-write"
  policy = file("s3policy.json")

  tags = {
    Name        = "Acc C&A Bucket"
  }
  
  logging = {
    target_bucket = "test-bucket-cloud-auto-acc-interns"
    target_prefix = "logs/"
  }
  
 # Allow deletion of non-empty bucket
  force_destroy = true

 # attach_elb_log_delivery_policy = true
}

###############################################################################
#################### LAMBA FUNCTION FOR LOG DUPLICATION #######################
########################### FROM CLOUDWATCH TO S3 #############################   
###############################################################################    

# LAMBDA IAM ROLE    
    
resource "aws_iam_role" "iam_for_lambda" {
  name = "iam_for_lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# AMAZON PROVIDED POLICIES ATTACHMENT TO LAMBDA IAM ROLE

resource "aws_iam_role_policy_attachment" "/AmazonS3FullAccess" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = arn:aws:iam::aws:policy/AmazonS3FullAccess
}   
    
resource "aws_iam_role_policy_attachment" "CloudWatchLogsFullAccess" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
}     
    
resource "aws_iam_role_policy_attachment" "CloudWatchEventsFullAccess" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = arn:aws:iam::aws:policy/CloudWatchEventsFullAccess
}   

# DEFINITION OF THE LAMBDA FUNCTION RESOURCE    
    
resource "aws_lambda_function" "test_lambda" {
  
  filename      = "lambda_function.py"
  function_name = "CloudWatch logs to S3 duplication"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "lambda_handler"
  
  source_code_hash = filebase64sha256("lambda_function.py")
  
  runtime = "Python3.6"
  
  timeout = 90
}

# ADDS A CLOUDWATCH EVENT RULE THAT TRIGGERS THE LAMBDA FUNCTION AUTOMATICALLY
    
resource "aws_cloudwatch_event_rule" "cw_rule" {
  name        = "send-logs-to-s3"
  description = "Sends logs to an S3 bucket every 5 minutes"

  schedule_expression = rate(5 minutes)

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.cw_rule.name
  target_id = "Lambda"
  arn       = aws_lambda_function.test_lambda.arn
}    
    
###############################################################################
################################## VAULT ######################################
###############################################################################  

# Add Vault here  
  
###############################################################################
################################# OUTPUTS #####################################
###############################################################################


output "cluster_id" {
  description = "EKS cluster ID."
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane."
  value       = module.eks.cluster_endpoint
}

output "config_map_aws_auth" {
  description = "A kubernetes configuration to authenticate to EKS cluster."
  value       = module.eks.config_map_aws_auth
}

# AWS and kubectl commands to show JupyterHub access IP
resource "null_resource" "Jhub" {

  provisioner "local-exec" {
    command = "aws eks --region eu-central-1 update-kubeconfig --name test-cluster"
  }

  provisioner "local-exec" {
    command = "kubectl --namespace=default get svc proxy-public"
  }
}  
