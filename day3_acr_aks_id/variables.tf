variable "location" {
	type    = string
	default = "eastus"
}

variable "prefix" {
	type    = string
	default = "lab"
}

variable "kubernetes_version" {
  type    = string
  default = "1.33.1"
}

variable "system_node_count" {
	type    = number
	default = 1
}

variable "user_node_count_min" {
	type    = number
	default = 1
}

variable "user_node_count_max" {
	type    = number
	default = 3
}