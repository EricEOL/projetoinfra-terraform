terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.26"
    }
  }
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}

resource "azurerm_resource_group" "rg-projetoinfra" {
    name     = "rg-projetoinfra"
    location = "eastus"
}

resource "azurerm_virtual_network" "vn-projetoinfra" {
    name                = "vn-projetoinfra"
    location            = "eastus"
    address_space       = ["10.0.0.0/16"]
    resource_group_name = azurerm_resource_group.rg-projetoinfra.name
}

resource "azurerm_subnet" "sbnet-projetoinfra" {
    name                 = "sbnet-projetoinfra"
    resource_group_name  = azurerm_resource_group.rg-projetoinfra.name
    virtual_network_name = azurerm_virtual_network.vn-projetoinfra.name
    address_prefixes       = ["10.0.1.0/24"]

    depends_on = [azurerm_resource_group.rg-aulainfra, azurerm_virtual_network.vnet-aulainfra]

}

resource "azurerm_public_ip" "pbip-projetoinfra" {
    name                         = "pbip-projetoinfra"
    resource_group_name          = azurerm_resource_group.rg-projetoinfra.name
    allocation_method            = "Static"
    location                     = "eastus"
}

resource "azurerm_network_security_group" "nsg-projetoinfra" {
    name                = "nsg-projetoinfra"
    location            = "eastus"
    resource_group_name = azurerm_resource_group.rg-projetoinfra.name

    security_rule {
        name                       = "mysql"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3306"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    security_rule {
        name                       = "ssh"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_network_interface" "ni-projetoinfra" {
    name                      = "ni-projetoinfra"
    location                  = "eastus"
    resource_group_name       = azurerm_resource_group.rg-projetoinfra.name

    ip_configuration {
        name                          = "internal"
        subnet_id                     = azurerm_subnet.sbnet-projetoinfra.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.pbip-projetoinfra.id
    }
}


resource "azurerm_network_interface_security_group_association" "exampleAulaTerraform" {
    network_interface_id      = azurerm_network_interface.ni-projetoinfra.id
    network_security_group_id = azurerm_network_security_group.nsg-projetoinfra.id
}

data "azurerm_public_ip" "ip_data_db" {
  name                = azurerm_public_ip.pbip-projetoinfra.name
  resource_group_name = azurerm_resource_group.rg-projetoinfra.name
}

resource "azurerm_storage_account" "sql-projetoinfra" {
    name                        = "sql-projetoinfra"
    resource_group_name         = azurerm_resource_group.rg-projetoinfra.name
    location                    = "eastus"
    account_tier                = "Standard"
    account_replication_type    = "LRS"
}

resource "azurerm_linux_virtual_machine" "vmdb-projetoinfra" {
    name                  = "vmdb-projetoinfra"
    location              = "eastus"
    resource_group_name   = azurerm_resource_group.rg-projetoinfra.name
    network_interface_ids = [azurerm_network_interface.ni-projetoinfra.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "myOsDiskMySQL"
        caching           = "ReadWrite"
        storage_account_type = "Premium_LRS"
    }

    source_image_reference {
        publisher = "Canonical"
        offer     = "UbuntuServer"
        sku       = "18.04-LTS"
        version   = "latest"
    }

    computer_name  = "myvmsql"
    admin_username = var.user
    admin_password = var.password
    disable_password_authentication = false

    boot_diagnostics {
        storage_account_uri = azurerm_storage_account.sql-projetoinfra.primary_blob_endpoint
    }

    depends_on = [ azurerm_resource_group.rg-projetoinfra ]
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.vmdb-projetoinfra]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
    provisioner "file" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.ip_data_db.ip_address
        }
        source = "config"
        destination = "/home/adminuser"
    }

    depends_on = [ time_sleep.wait_30_seconds_db ]
}

resource "null_resource" "deploy_db" {
    triggers = {
        order = null_resource.upload_db.id
    }
    provisioner "remote-exec" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.ip_data_db.ip_address
        }
        inline = [
            "sudo apt-get update",
            "sudo apt-get install -y mysql-server-5.7",
            "sudo mysql < /home/adminuser/config/user.sql",
            "sudo cp -f /home/adminuser/config/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
            "sudo service mysql restart",
            "sleep 20",
        ]
    }
}