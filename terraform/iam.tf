resource "yandex_iam_service_account" "cluster" {
  name        = "${var.cluster_name}-cluster"
  description = "Service account for the Kubernetes control plane"
  folder_id   = local.folder_id
}

resource "yandex_resourcemanager_folder_iam_member" "cluster" {
  for_each = toset([
    "k8s.clusters.agent",       # создание узлов, дисков и внутренних балансировщиков
    "vpc.publicAdmin",          # публичный IP мастера
    "k8s.tunnelClusters.agent", # туннельный режим Cilium (VxLAN)
  ])

  folder_id = local.folder_id
  role      = each.value
  member    = "serviceAccount:${yandex_iam_service_account.cluster.id}"
}

resource "yandex_iam_service_account" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "Service account for Kubernetes worker nodes"
  folder_id   = local.folder_id
}

resource "yandex_resourcemanager_folder_iam_member" "nodes" {
  for_each = toset([
    "container-registry.images.puller", # образы из Yandex Container Registry
    "monitoring.editor",                # метрики узлов в Yandex Monitoring
  ])

  folder_id = local.folder_id
  role      = each.value
  member    = "serviceAccount:${yandex_iam_service_account.nodes.id}"
}
