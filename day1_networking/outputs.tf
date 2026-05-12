output "vnet_id"   { value = azurerm_virtual_network.main.id }
output "vnet_name" { value = azurerm_virtual_network.main.name }
output "resource_group_name" { value = azurerm_resource_group.networking.name }
output "subnet_ids" {
  value = {
    public   = azurerm_subnet.public.id
    private  = azurerm_subnet.private.id
    database = azurerm_subnet.database.id
  }
}