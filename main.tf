###############################################################################
################################ DATA SOURCES #################################
###############################################################################

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

  preferred_instance_types = ["t3.micro"]
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
  public_subnets  = ["10.0.101.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = true
  single_nat_gateway   = true

}

###############################################################################
############################### KUBERNETES ####################################
###############################################################################

data "aws_eks_cluster" "cluster" {
  name = module.eks-cluster.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks-cluster.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}

###############################################################################
############################### EKS CLUSTER ###################################
###############################################################################

module "eks-cluster" {
  source          = "terraform-aws-modules/eks/aws"
  cluster_name    = "test-cluster"
  cluster_version = "1.17"
  subnets         = module.vpc.private_subnets
  vpc_id          = module.vpc.vpc_id

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
    },
  ]
}

###############################################################################
################################# TODO ########################################
###############################################################################

# Add Helm module to deploy Jypiterhub
# Add module for Cloudwatch monitoring
# Add s3 bucket

###############################################################################
################################# OUTPUTS #####################################
###############################################################################


output "cluster_id" {
  description = "EKS cluster ID."
  value       = module.eks-cluster.cluster_id
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane."
  value       = module.eks-cluster.cluster_endpoint
}

output "config_map_aws_auth" {
  description = "A kubernetes configuration to authenticate to EKS cluster."
  value       = module.eks-cluster.config_map_aws_auth
}
