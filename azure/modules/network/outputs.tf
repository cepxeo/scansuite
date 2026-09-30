output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "aca_subnet_id" {
  # Through the NSG association, so nothing lands in the subnet before it is
  # guarded.
  value = azurerm_subnet_network_security_group_association.aca.subnet_id
}

output "postgres_subnet_id" {
  value = azurerm_subnet_network_security_group_association.postgres.subnet_id
}

output "egress_ip" {
  description = "Static egress address, when the NAT gateway is enabled."
  value       = one(azurerm_public_ip.nat[*].ip_address)
}
