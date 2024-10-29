variable "region" {
  description = "AWS region"
  type        = string
}

variable "custom_ami_id_amd64" {
  description = "Custom AMI ID for AMD64 instances"
  type        = string
}

variable "custom_ami_id_arm64" {
  description = "Custom AMI ID for ARM64 instances"
  type        = string
}