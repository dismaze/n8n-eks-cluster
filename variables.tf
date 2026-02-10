variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-3"
}

variable "domain_name" {
  description = "Domain name used by AWS"
  type        = string
}

variable "subdomain_name" {
  description = "Subdomain for the n8n management"
  type        = string
}

variable "public_ip_address" {
  description = "Public IP of the computer from where Terraform is running"
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.public_ip_address))
    error_message = "The public_ip_address must be a valid IPv4 address (e.g., 8.8.8.8)."
  }
}

variable "instance_types" {
  description = "List of EC2 instance types for the EKS nodes"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "min_size" {
  description = "Minimum number of nodes in the EKS node group"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "Maximum number of nodes in the EKS node group"
  type        = number
  default     = 3
}

variable "desired_size" {
  description = "Desired number of nodes in the EKS node group"
  type        = number
  default     = 2
}

variable "cidr" {
  description = "Primary VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnets" {
  description = "Subnets with internet access (for Load Balancers)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnets" {
  description = "Subnets with no direct internet access (for the Pods)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "database_subnets" {
  description = "Subnets for the databases (RDS)"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}

variable "username" {
  description = "Database username"
  type        = string
  default     = "n8nadmin"
}

variable "password" {
  description = "Database password"
  type        = string
  default     = null
}

variable "port" {
  description = "Database port"
  type        = number
  default     = 5432
}

variable "db_ca_url" {
  description = "URL of the CA used to connect to the database"
  type        = string
}

variable "main_count" {
  description = "Number of main pods"
  type    = number
  default = 1
}

variable "worker_count" {
  description = "Number of worker pods"
  type    = number
  default = 2
}


locals {
  n8n_subdomain_name = "${var.subdomain_name}.${var.domain_name}"
  db_name = "n8n"

  common_n8n_env = [
    { name = "DB_TYPE", value = "postgresdb" },
    { name = "DB_POSTGRESDB_HOST", value = module.db.db_instance_address },
    { name = "DB_POSTGRESDB_PORT", value = var.port },
    { name = "DB_POSTGRESDB_DATABASE", value = local.db_name },
    { name = "DB_POSTGRESDB_USER", value = var.username },
    { name = "DB_POSTGRESDB_SSL_ENABLED", value = "true" },
    { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = "true" },
    { name = "DB_POSTGRESDB_SSL_CA_FILE", value = "/home/node/certs/ca.crt" },
    { name = "EXECUTIONS_MODE", value = "queue" },
    { name = "QUEUE_BULL_REDIS_HOST", value = "redis" },
    { name = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS", value = "false" }
  ]
}