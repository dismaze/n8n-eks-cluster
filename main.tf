terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
      kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }

  # Uncomment for remote backend
  #backend "s3" {
  #  bucket         = "terraform-n8n-state"
  #  key            = "terraform/terraform.tfstate"
  #  region         = "eu-west-3"
  #  encrypt        = true
  #  use_lockfile   = true
  #}
}

# Primary provider
provider "aws" {
  region = var.aws_region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

# Request from AWS for the available zones in current region
data "aws_availability_zones" "available" {
  state = "available"
}

# Configure VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "n8n-k8s-vpc"
  cidr = "10.0.0.0/16"

  azs = slice(data.aws_availability_zones.available.names, 0, 2) # Gets the first 2 zones from the list (e.g., eu-west-3a and eu-west-3b)
  public_subnets   = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets  = ["10.0.10.0/24", "10.0.11.0/24"]
  database_subnets = ["10.0.20.0/24", "10.0.21.0/24"]

  # NAT Gateway Configuration
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  create_database_subnet_group = true
  create_database_subnet_route_table = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1 # Required for Public Load Balancers
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "kubernetes.io/cluster/n8n-eks-cluster" = "shared"
  }
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "n8n-eks-cluster"
  cluster_version = "1.35"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets
  
  enable_cluster_creator_admin_permissions = true

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access_cidrs = [
    "${var.public_ip_address}/32",
    "${module.vpc.nat_public_ips[0]}/32"
  ]

  eks_managed_node_groups = {
    main = {
      instance_types = var.instance_types
      min_size     = var.min_size
      max_size     = var.max_size
      desired_size = var.desired_size
    }
  }
}

# Fetch the n8n database password from SSM
data "aws_ssm_parameter" "rds_password" {
  name            = "n8n_pg_password"
  with_decryption = true
}

# Fetch the encryption key from SSM
data "aws_ssm_parameter" "n8n_encryption_key" {
  name            = "n8n_encryption_key"
  with_decryption = true
}

# Create Kubernetes secrets
resource "kubernetes_secret_v1" "n8n_secrets" {
  metadata {
    name      = "n8n-secrets"
    namespace = "default"
  }

  data = {
    "DB_POSTGRESDB_PASSWORD" = data.aws_ssm_parameter.rds_password.value
    "N8N_ENCRYPTION_KEY"     = data.aws_ssm_parameter.n8n_encryption_key.value 
  }

  type = "Opaque"
}

# Database (Postgres RDS)
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "n8n-postgres"
  engine     = "postgres"
  family         = "postgres16"
  engine_version = "16.11"
  instance_class = "db.t3.micro"
  allocated_storage = 20
  manage_master_user_password = false

  db_name  = local.db_name
  username = var.username
  password = data.aws_ssm_parameter.rds_password.value
  port     = var.port

  vpc_security_group_ids = [module.db_sg.security_group_id]
  db_subnet_group_name   = module.vpc.database_subnet_group
  skip_final_snapshot    = true
}

# Security Group
module "db_sg" {
  source = "terraform-aws-modules/security-group/aws//modules/postgresql"
  name   = "n8n-db-sg"
  vpc_id = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      rule                     = "postgresql-tcp"
      source_security_group_id = module.eks.node_security_group_id
    }
  ]
}

# 1. Download the Amazon RDS Global Bundle
data "http" "rds_ca_bundle" {
  url = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
}

# 2. Create the Kubernetes Secret using the downloaded content
resource "kubernetes_secret_v1" "rds_ca" {
  metadata {
    name      = "rds-ca"
    namespace = "default"
  }

  data = {
    "ca.crt" = data.http.rds_ca_bundle.response_body
  }

  type = "Opaque"
}

# Redis Service for n8n Workers
resource "kubernetes_deployment_v1" "redis" {
  metadata { name = "redis" }
  spec {
    selector { match_labels = { app = "redis" } }
    template {
      metadata { labels = { app = "redis" } }
      spec {
        container {
          name  = "redis"
          image = "redis:alpine"
          port { container_port = 6379 }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "redis_service" {
  metadata { name = "redis" }
  spec {
    selector = { app = "redis" }
    port { port = 6379 }
  }
}

# Main Nodes
resource "kubernetes_deployment_v1" "n8n_main" {
  metadata {
    name = "n8n-main"
    labels = {
      app  = "n8n"
      role = "main"
    }
  }

  spec {
    replicas = var.main_count
    selector {
      match_labels = {
        app  = "n8n"
        role = "main"
      }
    }

    template {
      metadata {
        labels = {
          app  = "n8n"
          role = "main"
        }
      }

      spec {
        container {
          name  = "n8n"
          image = "docker.n8n.io/n8nio/n8n:latest"

          port {
            container_port = 5678
          }

          volume_mount {
            name       = "rds-ca-volume"
            mount_path = "/home/node/certs"
            read_only  = true
          }

          dynamic "env" {
            for_each = local.common_n8n_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          env {
            name  = "N8N_PORT"
            value = "5678"
          }

          env {
            name  = "N8N_PROTOCOL"
            value = "https"
          }

          env {
            name  = "N8N_HOST"
            value = local.n8n_subdomain_name
          }

          env {
            name  = "WEBHOOK_URL"
            value = "https://${local.n8n_subdomain_name}/"
          }

          env {
            name = "DB_POSTGRESDB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.n8n_secrets.metadata[0].name
                key  = "DB_POSTGRESDB_PASSWORD"
              }
            }
          }

          env {
            name = "N8N_ENCRYPTION_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.n8n_secrets.metadata[0].name
                key  = "N8N_ENCRYPTION_KEY"
              }
            }
          }
        }

        volume {
          name = "rds-ca-volume"
          secret {
            secret_name = kubernetes_secret_v1.rds_ca.metadata[0].name
            items {
              key  = "ca.crt"
              path = "ca.crt"
            }
          }
        }
      }
    }
  }
}

# Worker Nodes
resource "kubernetes_deployment_v1" "n8n_worker" {
  metadata {
    name = "n8n-worker"
    labels = {
      app  = "n8n"
      role = "worker"
    }
  }

  spec {
    replicas = var.worker_count
    selector {
      match_labels = {
        app  = "n8n"
        role = "worker"
      }
    }

    template {
      metadata {
        labels = {
          app  = "n8n"
          role = "worker"
        }
      }

      spec {
        container {
          name  = "n8n"
          image = "docker.n8n.io/n8nio/n8n:latest"
          args  = ["worker"]

          volume_mount {
            name       = "rds-ca-volume"
            mount_path = "/home/node/certs"
            read_only  = true
          }

          dynamic "env" {
            for_each = local.common_n8n_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          env {
            name = "DB_POSTGRESDB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.n8n_secrets.metadata[0].name
                key  = "DB_POSTGRESDB_PASSWORD"
              }
            }
          }

          env {
            name = "N8N_ENCRYPTION_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.n8n_secrets.metadata[0].name
                key  = "N8N_ENCRYPTION_KEY"
              }
            }
          }
        }

        volume {
          name = "rds-ca-volume"
          secret {
            secret_name = kubernetes_secret_v1.rds_ca.metadata[0].name
            items {
              key  = "ca.crt"
              path = "ca.crt"
            }
          }
        }
      }
    }
  }
}

# Service exposing n8n
resource "kubernetes_service_v1" "n8n_service" {
  metadata {
    name = "n8n-service" 
    annotations = {
      # 1. Attach the ACM Certificate
      "service.beta.kubernetes.io/aws-load-balancer-ssl-cert" = aws_acm_certificate.n8n_cert.arn
      
      # 2. Enable SSL for Port 443
      "service.beta.kubernetes.io/aws-load-balancer-ssl-ports" = "443"
      
      # 3. Redirect from 80 to 443
      "service.beta.kubernetes.io/aws-load-balancer-ssl-redirect" = "443"

      # 4. Set the Health Check
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-check-interval" = "10"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout"        = "5"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold" = "3"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold"   = "2"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-target" = "HTTP:5678/healthz"
    }
  }
  spec {
    selector = { app = "n8n" }
    port {
      name        = "http"
      port        = 80
      target_port = 5678
    }
    port {
      name        = "https"
      port        = 443
      target_port = 5678
    }
    type = "LoadBalancer"
  }
}

# Obtain the primary DNS zone (for the "domain_name" variable)
data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}

# Route 53 Subdomain Record for n8n
resource "aws_route53_record" "n8n" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = local.n8n_subdomain_name
  type    = "CNAME"
  ttl     = 300
  # Pointing to the Public IP of the load balancer
  records = [kubernetes_service_v1.n8n_service.status.0.load_balancer.0.ingress.0.hostname]
}

# Request SSL Certificate
resource "aws_acm_certificate" "n8n_cert" {
  domain_name       = local.n8n_subdomain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Automatically create the DNS record for ACM validation
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.n8n_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.primary.zone_id
}

# Wait for validation to complete
resource "aws_acm_certificate_validation" "n8n_cert" {
  certificate_arn         = aws_acm_certificate.n8n_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}