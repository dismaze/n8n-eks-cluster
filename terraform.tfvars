# General settings
aws_region      = "eu-west-3"                    # AWS region (eu-west-3 = Paris)
domain_name     = "yourdomain.com"               # Domain in AWS
subdomain_name  = "n8n"                          # Subdomain (n8n.yourdomain.com)
public_ip_address = "YOUR-PUBLIC-IP-ADDRESS"     # Your public IP

# EKS Kubernetes cluster - Worker nodes
instance_types = ["t3.small"]  # t3.small (dev) or t3.medium (production)
min_size       = 2             # Minimum worker nodes
max_size       = 3             # Maximum worker nodes (for auto-scaling, not implemented)
desired_size   = 2             # Initial number of nodes

# n8n application pods
main_count   = 1  # Main n8n pods (UI/API)
worker_count = 2  # Worker pods

# PostgreSQL database
username = "n8nadmin"  # Database username
port     = "5432"      # PostgreSQL port

# VPC & Networking
cidr = "10.0.0.0/16"                            	# VPC CIDR range
public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]    # Load balancer, NAT
private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]  # EKS nodes
database_subnets = ["10.0.20.0/24", "10.0.21.0/24"] # RDS database