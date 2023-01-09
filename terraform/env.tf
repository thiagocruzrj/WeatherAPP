resource "azurerm_resource_group" "aksrg" {
  name     = "${var.resource_group_name}-${random_integer.random_int.result}"
  location = var.location

  tags = {
    environment = var.environment
    project     = "azbgaks"
  }
}

resource "azurerm_virtual_network" "kubevnet" {
  name                = "${var.dns_prefix}-${random_integer.random_int.result}-vnet"
  address_space       = ["10.0.0.0/20"]
  location            = azurerm_resource_group.aksrg.location
  resource_group_name = azurerm_resource_group.aksrg.name

  tags = {
    environment = var.environment
    project     = "azbgaks"
  }
}

resource "azurerm_subnet" "gwnet" {
  name                 = "gw-1-subnet"
  resource_group_name  = azurerm_resource_group.aksrg.name
  address_prefixes     = ["10.0.1.0/24"]
  virtual_network_name = azurerm_virtual_network.kubevnet.name
}

resource "azurerm_subnet" "acinet" {
  name                 = "aci-2-subnet"
  resource_group_name  = azurerm_resource_group.aksrg.name
  address_prefixes     = ["10.0.2.0/24"]
  virtual_network_name = azurerm_virtual_network.kubevnet.name
}

resource "azurerm_subnet" "fwnet" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.aksrg.name
  address_prefixes     = ["10.0.6.0/24"]
  virtual_network_name = azurerm_virtual_network.kubevnet.name
}

resource "azurerm_subnet" "ingnet" {
  name                 = "ing-4-subnet"
  resource_group_name  = azurerm_resource_group.aksrg.name
  address_prefixes     = ["10.0.4.0/24"]
  virtual_network_name = azurerm_virtual_network.kubevnet.name
}

resource "azurerm_subnet" "aksnet" {
  name                 = "aks-5-subnet"
  resource_group_name  = azurerm_resource_group.aksrg.name
  address_prefixes     = ["10.0.5.0/24"]
  virtual_network_name = azurerm_virtual_network.kubevnet.name
}

resource "azurerm_public_ip" "appgw_ip" {
  name                = "${var.dns_prefix}-${random_integer.random_int.result}-appgwpip"
  resource_group_name = azurerm_resource_group.aksrg.name
  location            = azurerm_resource_group.aksrg.location
  allocation_method   = "Dynamic"
}

resource "azurerm_application_gateway" "appgw" {
  name                = "${var.dns_prefix}-${random_integer.random_int.result}-appgw"
  resource_group_name = azurerm_resource_group.aksrg.name
  location            = azurerm_resource_group.aksrg.location

  sku {
    name     = "Standard_Small"
    tier     = "Standard"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "my-gateway-ip-configuration"
    subnet_id = azurerm_subnet.gwnet.id
  }

  frontend_port {
    name = "frontend-port-name"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontend-config-name"
    public_ip_address_id = azurerm_public_ip.appgw_ip.id
  }

  backend_address_pool {
    name  = "backend-pool-name"
    fqdns = ["${azurerm_public_ip.nginx_ingress.ip_address}.xip.io", "${azurerm_public_ip.nginx_ingress-stage.ip_address}.xip.io"]
  }

  backend_http_settings {
    name                  = "http-setting-name"
    cookie_based_affinity = "Disabled"
    path                  = "/"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 1
    connection_draining {
      enabled           = true
      drain_timeout_sec = 30
    }
  }

  probe {
    name                = "probe"
    protocol            = "http"
    path                = "/"
    host                = "${azurerm_public_ip.nginx_ingress.ip_address}.xip.io"
    interval            = "30"
    timeout             = "30"
    unhealthy_threshold = "3"
  }

  http_listener {
    name                           = "listener-name"
    frontend_ip_configuration_name = "frontend-config-name"
    frontend_port_name             = "frontend-port-name"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "listener-name"
    backend_address_pool_name  = "backend-pool-name"
    backend_http_settings_name = "http-setting-name"
  }
}

resource "azurerm_application_insights" "aksainsights" {
  name                = "${var.dns_prefix}-${random_integer.random_int.result}-ai"
  application_type    = "Node.JS"
  location            = "West Europe"
  resource_group_name = azurerm_resource_group.aksrg.name

  tags = {
    environment = var.environment
    project     = "azbgaks"
  }
}

resource "azurerm_log_analytics_workspace" "akslogs" {
  name                = "${var.dns_prefix}-${random_integer.random_int.result}-lga"
  location            = azurerm_resource_group.aksrg.location
  resource_group_name = azurerm_resource_group.aksrg.name
  sku                 = "PerGB2018"

  tags = {
    environment = var.environment
    project     = "azbgaks"
  }
}

resource "azurerm_log_analytics_solution" "akslogs" {
  solution_name         = "ContainerInsights"
  location              = azurerm_resource_group.aksrg.location
  resource_group_name   = azurerm_resource_group.aksrg.name
  workspace_resource_id = azurerm_log_analytics_workspace.akslogs.id
  workspace_name        = azurerm_log_analytics_workspace.akslogs.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ContainerInsights"
  }
}

resource "azurerm_kubernetes_cluster" "akstf" {
  name                    = "${var.dns_prefix}-${random_integer.random_int.result}"
  location                = azurerm_resource_group.aksrg.location
  resource_group_name     = azurerm_resource_group.aksrg.name
  dns_prefix              = var.dns_prefix
  kubernetes_version      = var.kubernetes_version
  private_cluster_enabled = true
  node_resource_group     = "${azurerm_resource_group.aksrg.name}_nodes_${azurerm_resource_group.aksrg.location}"
  linux_profile {
    admin_username = "phoenix"

    ssh_key {
      key_data = file("${var.ssh_public_key}")
    }
  }

  default_node_pool {
    name                = "default"
    node_count          = 1
    vm_size             = "Standard_DS2_v2" #"Standard_F4s" # Standard_DS2_v2
    os_disk_size_gb     = 120
    max_pods            = 30
    vnet_subnet_id      = azurerm_subnet.aksnet.id
    type                = "VirtualMachineScaleSets"
    enable_auto_scaling = true
    min_count           = 1
    max_count           = 4
  }

  network_profile {
    network_plugin     = "azure"
    service_cidr       = "10.2.0.0/24"
    dns_service_ip     = "10.2.0.10"
    docker_bridge_cidr = "172.17.0.1/16"
    load_balancer_sku  = "standard"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    environment = var.environment
    project     = "azbgaks"
  }
}

# Create Static Public IP Address to be used by Nginx Ingress
resource "azurerm_public_ip" "nginx_ingress" {
  name                = "nginx-ingress-pip"
  location            = azurerm_kubernetes_cluster.akstf.location
  resource_group_name = azurerm_kubernetes_cluster.akstf.node_resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.dns_prefix}-${random_integer.random_int.result}"

  depends_on = [azurerm_kubernetes_cluster.akstf]
}


resource "azurerm_public_ip" "nginx_ingress-stage" {
  name                = "nginx-ingress-pip-stage"
  location            = azurerm_kubernetes_cluster.akstf.location
  resource_group_name = azurerm_kubernetes_cluster.akstf.node_resource_group
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.dns_prefix}-${random_integer.random_int.result}-stage"

  depends_on = [azurerm_kubernetes_cluster.akstf]
}

resource "kubernetes_namespace" "nginx-ns" {
  metadata { name = "nginx" }

  depends_on = [azurerm_kubernetes_cluster.akstf]
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.akstf.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.akstf.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.akstf.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.akstf.kube_config.0.cluster_ca_certificate)
}

# https://www.terraform.io/docs/providers/helm/index.html
provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.akstf.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.akstf.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.akstf.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.akstf.kube_config.0.cluster_ca_certificate)
    config_path            = "ensure-that-we-never-read-kube-config-from-home-dir"
  }
}

# Install Nginx Ingress using Helm Chart
# https://www.terraform.io/docs/providers/helm/release.html
resource "helm_release" "nginx_ingress" {
  name         = "nginx-ingress"
  repository   = "https://kubernetes-charts.storage.googleapis.com"
  chart        = "nginx-ingress"
  namespace    = "nginx"
  force_update = "true"
  timeout      = "500"

  set {
    name  = "controller.service.externalTrafficPolicy"
    value = "Local"
  }

  set {
    name  = "controller.service.loadBalancerIP"
    value = azurerm_public_ip.nginx_ingress.ip_address
  }

  set {
    name  = "controller.replicaCount"
    value = "2"
  }

  set {
    name  = "controller.metrics.enabled"
    value = "true"
  }

  set {
    name  = "controller.stats.enabled"
    value = "true"
  }

  depends_on = [azurerm_kubernetes_cluster.akstf, kubernetes_namespace.nginx-ns, azurerm_public_ip.nginx_ingress]
}

resource "null_resource" "get-credentials" {
  provisioner "local-exec" {
    command = "az aks get-credentials --resource-group ${azurerm_resource_group.aksrg.name} --name ${azurerm_kubernetes_cluster.akstf.name}"
  }
  depends_on = [azurerm_kubernetes_cluster.akstf]
}

# set env variables for scripts
resource "null_resource" "set-env-vars" {
  provisioner "local-exec" {
    command = "export KUBE_GROUP=${azurerm_resource_group.aksrg.name}; export KUBE_NAME=${azurerm_kubernetes_cluster.akstf.name}; export LOCATION=${var.location}"
  }
  depends_on = [azurerm_kubernetes_cluster.akstf]
}

output "NODE_GROUP" {
  value = "${azurerm_resource_group.aksrg.name}_nodes_${azurerm_resource_group.aksrg.location}"
}

output "ID" {
  value = azurerm_kubernetes_cluster.akstf.id
}

output "PUBLIC_IP" {
  value = azurerm_public_ip.nginx_ingress.ip_address
}

output "PUBLIC_IP_STAGE" {
  value = azurerm_public_ip.nginx_ingress-stage.ip_address
}

output "instrumentation_key" {
  value = azurerm_application_insights.aksainsights.instrumentation_key
}

output "AZURE_CONTAINER_REGISTRY_NAME" {
  value = azurerm_container_registry.aksacr.name
}

output "AZURE_KEYVAULT_NAME" {
  value = azurerm_key_vault.aksvault.name
}