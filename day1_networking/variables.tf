variable "location" {
  description = "Azure region"
  type = string
  default = "eastus"
}

variable "prefix" {
  description = "Prefix for resource names"
  type = string
  default = "lab"
}

variable "tags" {
  description = "tags applied to all resources"
  type = map(string)
  default = {
    environment = "dev"
    project     = "multi-cloud-poc"
    managed_by  = "terraform"
    day = "1"
  }
}