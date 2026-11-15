# TODO: удалить группу безопасности сети по умолчанию.
# Yandex Cloud вместе с сетью создаёт `default-sg-<network_id>` вне Terraform,
# поэтому в state её нет и `terraform destroy` её не удалит. Пока она висит на
# сети, удаление сети падает с ошибкой «Security group is in use». Перед
# destroy нужно либо удалить её командой
#   yc vpc security-group delete --id <id>
# либо завести в коде `yandex_vpc_default_security_group` (с import), чтобы
# Terraform управлял ею сам.
resource "yandex_vpc_network" "this" {
  name      = var.cluster_name
  folder_id = local.folder_id
  labels    = var.labels
}

locals {
  # Каждой зоне — своя /24 из network_cidr.
  node_subnets = {
    for index, zone in var.node_zones : zone => cidrsubnet(var.network_cidr, 8, index + 1)
  }

  node_subnet_ids = [for subnet in yandex_vpc_subnet.nodes : subnet.id]

  # Внутренний трафик кластера: подсети узлов, поды и сервисы.
  internal_cidrs = concat(
    [for subnet in yandex_vpc_subnet.nodes : subnet.v4_cidr_blocks[0]],
    [var.cluster_ipv4_range, var.service_ipv4_range],
  )
}

resource "yandex_vpc_subnet" "nodes" {
  for_each = local.node_subnets

  name           = "${var.cluster_name}-${each.key}"
  folder_id      = local.folder_id
  zone           = each.key
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = [each.value]
  labels         = var.labels
}

# Группа безопасности мастера: API доступен администратору и узлам.
resource "yandex_vpc_security_group" "master" {
  name       = "${var.cluster_name}-master"
  folder_id  = local.folder_id
  network_id = yandex_vpc_network.this.id
  labels     = var.labels

  ingress {
    description    = "Kubernetes API over TLS"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = var.admin_cidrs
  }

  ingress {
    description    = "Kubernetes API (6443)"
    protocol       = "TCP"
    port           = 6443
    v4_cidr_blocks = var.admin_cidrs
  }

  ingress {
    description    = "Service traffic from cluster subnets and pod/service ranges"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = local.internal_cidrs
  }

  egress {
    description    = "Allow all egress"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Группа безопасности узлов: обмен внутри кластера, проверки балансировщика и интернет.
resource "yandex_vpc_security_group" "nodes" {
  name       = "${var.cluster_name}-nodes"
  folder_id  = local.folder_id
  network_id = yandex_vpc_network.this.id
  labels     = var.labels

  ingress {
    description    = "Node-to-node, master-to-node and pod traffic"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = local.internal_cidrs
  }

  ingress {
    description       = "Network Load Balancer health checks"
    protocol          = "TCP"
    from_port         = 0
    to_port           = 65535
    predefined_target = "loadbalancer_healthchecks"
  }

  dynamic "ingress" {
    for_each = var.allow_ssh_from_admin ? [1] : []

    content {
      description    = "SSH from admin networks"
      protocol       = "TCP"
      port           = 22
      v4_cidr_blocks = var.admin_cidrs
    }
  }

  egress {
    description    = "Allow all egress (image pulls, Yandex Cloud APIs)"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
