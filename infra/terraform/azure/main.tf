################################################################################
# Azure deployment – Solr + ZooKeeper + Redis on Azure VMs
#
# Creates:
#   - Resource group, VNet, subnet
#   - NSG rules (SSH, Solr, ZK internal)
#   - 3 Azure VMs (Solr + ZooKeeper co-located)
#   - 1 Azure VM (Redis)
#   - Azure Files NFS share for persistent data
#   - Azure Standard Load Balancer (TCP) for ZooKeeper internal LB
#   - Azure Application Gateway for Solr public access
################################################################################

terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# ── Resource group ───────────────────────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = "${var.name}-rg"
  location = var.location
}

# ── VNet + subnet ─────────────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "main" {
  name                = "${var.name}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_subnet" "main" {
  name                 = "${var.name}-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

# ── Network security group ────────────────────────────────────────────────────────
resource "azurerm_network_security_group" "main" {
  name                = "${var.name}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "solr-public"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8983"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "internal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["2181", "2888", "3888", "6379"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# ── Azure Files NFS share ────────────────────────────────────────────────────────
resource "azurerm_storage_account" "main" {
  name                     = replace("${var.name}data", "-", "")
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Premium"
  account_replication_type = "LRS"
  account_kind             = "FileStorage"
}

resource "azurerm_storage_share" "solr" {
  name                 = "solrdata"
  storage_account_name = azurerm_storage_account.main.name
  quota                = 1024
  enabled_protocol     = "NFS"
}

# ── Public IPs for VMs ───────────────────────────────────────────────────────────
resource "azurerm_public_ip" "solr_zk" {
  count               = 3
  name                = "${var.name}-node-${count.index + 1}-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "redis" {
  name                = "${var.name}-redis-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ── NICs ─────────────────────────────────────────────────────────────────────────
resource "azurerm_network_interface" "solr_zk" {
  count               = 3
  name                = "${var.name}-node-${count.index + 1}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.solr_zk[count.index].id
  }
}

resource "azurerm_network_interface" "redis" {
  name                = "${var.name}-redis-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.redis.id
  }
}

# ── VMs – Solr + ZooKeeper ────────────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "solr_zk" {
  count                           = 3
  name                            = "${var.name}-node-${count.index + 1}"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  size                            = var.solr_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.solr_zk[count.index].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.sh", {
    zoo_my_id      = count.index + 1
    registry       = var.registry
    image_repo     = var.image_repo
    image_tag      = var.image_tag
    nfs_account    = azurerm_storage_account.main.name
    nfs_share      = azurerm_storage_share.solr.name
    nfs_key        = azurerm_storage_account.main.primary_access_key
    redis_internal = azurerm_network_interface.redis.private_ip_address
    zk_lb_ip       = azurerm_lb.zookeeper.frontend_ip_configuration[0].private_ip_address
  }))

  tags = { Role = "solr-zookeeper", Project = var.name }
}

# ── VM – Redis ───────────────────────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "redis" {
  name                            = "${var.name}-redis"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  size                            = var.redis_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.redis.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init-redis.sh", {
    registry   = var.registry
    image_repo = var.image_repo
    image_tag  = var.image_tag
    nfs_account = azurerm_storage_account.main.name
    nfs_share   = azurerm_storage_share.solr.name
    nfs_key     = azurerm_storage_account.main.primary_access_key
  }))

  tags = { Role = "redis", Project = var.name }
}

# ── ZooKeeper internal load balancer (Standard LB, TCP) ──────────────────────────
resource "azurerm_lb" "zookeeper" {
  name                = "${var.name}-zk-lb"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "zk-frontend"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_lb_backend_address_pool" "zookeeper" {
  name            = "${var.name}-zk-pool"
  loadbalancer_id = azurerm_lb.zookeeper.id
}

resource "azurerm_network_interface_backend_address_pool_association" "zookeeper" {
  count                   = 3
  network_interface_id    = azurerm_network_interface.solr_zk[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.zookeeper.id
}

resource "azurerm_lb_probe" "zookeeper" {
  name                = "${var.name}-zk-probe"
  loadbalancer_id     = azurerm_lb.zookeeper.id
  protocol            = "Tcp"
  port                = 2181
  interval_in_seconds = 10
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "zookeeper" {
  name                           = "${var.name}-zk-rule"
  loadbalancer_id                = azurerm_lb.zookeeper.id
  protocol                       = "Tcp"
  frontend_port                  = 2181
  backend_port                   = 2181
  frontend_ip_configuration_name = "zk-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.zookeeper.id]
  probe_id                       = azurerm_lb_probe.zookeeper.id
}
