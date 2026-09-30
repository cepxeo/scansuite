###############################################################################
# VNet with two delegated subnets.
#
#   snet-aca  Container Apps environment (delegated to Microsoft.App). Carries
#             the Microsoft.Storage service endpoint, so the artifact Blob
#             account admits this subnet and nothing else.
#   snet-pg   PostgreSQL Flexible Server, private access (delegated).
#
# The optional NAT gateway pins the egress address the workers present to git
# hosts and model endpoints - the same reason infra/ reserves Cloud NAT IPs.
###############################################################################

resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "aca" {
  name                 = "snet-aca"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.aca_subnet_cidr]

  # The scans need the internet: git clones and the model endpoint. Without a
  # NAT gateway the environment egresses through its own address, which needs
  # default outbound access on the subnet.
  default_outbound_access_enabled = !var.enable_nat_gateway

  service_endpoint {
    service = "Microsoft.Storage"
  }

  delegation {
    name = "containerapps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                            = "snet-pg"
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.postgres_subnet_cidr]
  default_outbound_access_enabled = false

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

###############################################################################
# Network security groups
#
# Container Apps manages its own rules on the infrastructure subnet; this NSG
# adds nothing that would block them and exists so the subnet has one.
###############################################################################

resource "azurerm_network_security_group" "aca" {
  name                = "${var.prefix}-nsg-aca"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "aca" {
  subnet_id                 = azurerm_subnet.aca.id
  network_security_group_id = azurerm_network_security_group.aca.id
}

resource "azurerm_network_security_group" "postgres" {
  name                = "${var.prefix}-nsg-pg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  # Only the Container Apps subnet talks to the database.
  security_rule {
    name                       = "allow-aca-postgres"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = var.aca_subnet_cidr
    source_port_range          = "*"
    destination_address_prefix = var.postgres_subnet_cidr
    destination_port_range     = "5432"
  }

  # An HA server replicates to its standby inside this subnet.
  security_rule {
    name                       = "allow-intra-subnet"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_address_prefix      = var.postgres_subnet_cidr
    source_port_range          = "*"
    destination_address_prefix = var.postgres_subnet_cidr
    destination_port_range     = "*"
  }

  security_rule {
    name                       = "deny-vnet-other"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_address_prefix      = "VirtualNetwork"
    source_port_range          = "*"
    destination_address_prefix = var.postgres_subnet_cidr
    destination_port_range     = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  subnet_id                 = azurerm_subnet.postgres.id
  network_security_group_id = azurerm_network_security_group.postgres.id
}

###############################################################################
# Optional NAT gateway with a static egress address
###############################################################################

resource "azurerm_public_ip" "nat" {
  count               = var.enable_nat_gateway ? 1 : 0
  name                = "${var.prefix}-nat-ip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  count                   = var.enable_nat_gateway ? 1 : 0
  name                    = "${var.prefix}-nat"
  location                = var.location
  resource_group_name     = var.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  count                = var.enable_nat_gateway ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.this[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "aca" {
  count          = var.enable_nat_gateway ? 1 : 0
  subnet_id      = azurerm_subnet.aca.id
  nat_gateway_id = azurerm_nat_gateway.this[0].id
}
