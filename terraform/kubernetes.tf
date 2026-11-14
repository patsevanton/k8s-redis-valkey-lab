resource "yandex_kubernetes_cluster" "this" {
  name                    = var.cluster_name
  description             = "Redis vs Valkey lab: Helm charts, operators, failover"
  folder_id               = local.folder_id
  network_id              = yandex_vpc_network.this.id
  cluster_ipv4_range      = var.cluster_ipv4_range
  service_ipv4_range      = var.service_ipv4_range
  service_account_id      = yandex_iam_service_account.cluster.id
  node_service_account_id = yandex_iam_service_account.nodes.id
  release_channel         = var.release_channel
  network_policy_provider = "CALICO"
  labels                  = var.labels

  master {
    version = var.kubernetes_version

    # Зональный мастер дешевле регионального. Региональный требует подсетей
    # во всех трёх зонах ru-central1, а rc1b недоступна.
    zonal {
      zone      = var.zone
      subnet_id = yandex_vpc_subnet.nodes[var.zone].id
    }

    public_ip          = var.master_public_ip
    security_group_ids = [yandex_vpc_security_group.master.id]

    maintenance_policy {
      auto_upgrade = var.master_auto_upgrade

      maintenance_window {
        start_time = var.maintenance_start_time
        duration   = var.maintenance_duration
      }
    }
  }

  lifecycle {
    precondition {
      condition     = contains(var.node_zones, var.zone)
      error_message = "Зона мастера (var.zone) должна входить в var.node_zones."
    }
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.cluster]
}

resource "yandex_kubernetes_node_group" "workers" {
  cluster_id  = yandex_kubernetes_cluster.this.id
  name        = "${var.cluster_name}-workers"
  description = "Worker nodes spread across available zones"
  version     = var.kubernetes_version
  labels      = var.labels

  instance_template {
    platform_id = var.node_platform_id
    labels      = var.labels

    resources {
      cores         = var.node_cores
      memory        = var.node_memory
      core_fraction = 100
    }

    boot_disk {
      type = var.node_disk_type
      size = var.node_disk_size
    }

    container_runtime {
      type = "containerd"
    }

    network_interface {
      subnet_ids         = local.node_subnet_ids
      nat                = true
      security_group_ids = [yandex_vpc_security_group.nodes.id]
    }

    scheduling_policy {
      preemptible = var.node_preemptible
    }
  }

  scale_policy {
    fixed_scale {
      size = var.node_count
    }
  }

  allocation_policy {
    dynamic "location" {
      for_each = yandex_vpc_subnet.nodes

      content {
        zone      = location.key
        subnet_id = location.value.id
      }
    }
  }

  deploy_policy {
    max_expansion   = 1
    max_unavailable = 1
  }

  maintenance_policy {
    auto_upgrade = var.node_auto_upgrade
    auto_repair  = true

    maintenance_window {
      start_time = var.maintenance_start_time
      duration   = var.maintenance_duration
    }
  }

  depends_on = [yandex_resourcemanager_folder_iam_member.nodes]
}
