# NOTE: there is intentionally no variable for AWS credentials. The previous
# `aws_secret_key` variable had a hard-coded default ("test-secret"). Credentials are
# supplied by the environment / an OIDC role, so no secret ever lives in this code.

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "orderflow-production"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version. Intentionally has no default: pick a version currently in EKS standard support."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnets for the cluster and nodes. Use at least two, in different availability zones."

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Provide at least two subnets in different availability zones for high availability."
  }
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 6
}
