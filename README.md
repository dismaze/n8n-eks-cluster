# n8n on AWS EKS with Terraform

A complete Infrastructure-as-Code solution for deploying n8n on Amazon EKS with PostgreSQL RDS, Redis, and automated SSL/TLS certificate management.

## 📋 Overview

This Terraform configuration sets up a production-grade Kubernetes cluster on AWS EKS with:
- VPC with public/private subnets across 2 availability zones
- EKS cluster with managed node groups
- PostgreSQL 16 RDS database
- Redis for n8n job queue
- Application Load Balancer with SSL/TLS
- Route53 DNS management
- ACM certificate automation

## 📊 Architecture

```
Internet
    ↓
Route53 (DNS)
    ↓
ALB (LoadBalancer Service)
    ↓
EKS Cluster
├── n8n-main (1 pod)
├── n8n-worker (2 pods)
└── Redis (1 pod)
    ↓
RDS PostgreSQL
```

## 🚀 Prerequisites

- AWS Account with appropriate IAM permissions
- Terraform >= 1.0
- AWS CLI configured
- kubectl installed
- Domain name registered and hosted in Route53
- Public IP address of your computer (for EKS API access)

## 📦 Required Secrets in AWS SSM Parameter Store

Create these parameters in AWS Systems Manager Parameter Store before deployment:

```bash
# PostgreSQL Password
aws ssm put-parameter \
  --name "n8n_pg_password" \
  --value "your-secure-password-here" \
  --type "SecureString"

# N8N Encryption Key (generate with: openssl rand -base64 32)
aws ssm put-parameter \
  --name "n8n_encryption_key" \
  --value "your-encryption-key-here" \
  --type "SecureString"
```

## 📝 Variable Configuration

Edit the `terraform.tfvars` file:

```hcl
# General settings
aws_region        = "eu-west-3"                  # AWS region (eu-west-3 = Paris)
domain_name       = "yourdomain.com"             # Domain in AWS
subdomain_name    = "n8n"                        # Subdomain (n8n.yourdomain.com)
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
```

## 🎯 Deployment Steps

1. **Initialize Terraform**
   ```bash
   terraform init
   ```

2. **Review planned changes**
   ```bash
   terraform plan -out=tfplan
   ```

3. **Apply configuration**
   ```bash
   terraform apply tfplan
   ```

4. (optional) **Destroy environment**
   ```bash
   terraform destroy
   ```

## 🔍 Post-Deployment Verification

```bash
# Check cluster health
kubectl get nodes
kubectl get pods --all-namespaces

# Check services
kubectl get svc n8n-service
kubectl describe svc n8n-service

# Check n8n logs
kubectl logs -f deployment/n8n-main
kubectl logs -f deployment/n8n-worker

# Check DNS
nslookup n8n.mydomain.com
```

## ⚠️ Production Readiness Issues

1. **Single NAT Gateway** - Creates single point of failure, change to `one_nat_gateway_per_az = true`
2. **S3 backend not configured** - Terraform state stored locally, needs remote S3 backend with locking
3. **EKS secrets encryption** - Not enabled, add KMS encryption for etcd secrets
4. **Container resource limits** - Not set, add CPU/memory requests and limits
5. **Database failover** - Set `multi_az = true` to enable multi-AZ
6. **Database backups** - `skip_final_snapshot = true` loses data, set to `false` with 30-day retention
7. **Redis persistence** - In-memory only, add PersistentVolumeClaim
8. **Pod health checks** - Liveness/readiness probes not configured
9. **Pod Disruption Budgets** - Not implemented, could be done
10. **Cluster autoscaling** - Not implemented, could be done
11. **EKS control plane logging** - Not implemented, could be done
12. **RBAC/Network policies** - Not implemented, could be done
13. **Monitoring/Alerting** - Not implemented, could be done

## 🔗 Related Resources

- [n8n Documentation](https://docs.n8n.io)
- [AWS EKS Best Practices](https://docs.aws.amazon.com/eks/latest/best-practices/introduction.html)
- [Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Kubernetes Documentation](https://kubernetes.io/docs/)