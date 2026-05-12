terraform {
  backend "azurerm" {
    subscription_id      = "e3bda1e9-e6e9-45a5-b2ee-d3d7a754b594"
    resource_group_name  = "rg-tfstate"
    storage_account_name = "mainstterraform8517515"
    container_name       = "tfstate"
    key                  = "day1_networking/terraform.tfstate"
  }
}