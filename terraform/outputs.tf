output "cluster_id" {
  description = "Идентификатор кластера Managed Service for Kubernetes."
  value       = yandex_kubernetes_cluster.this.id
}

output "cluster_name" {
  description = "Имя кластера."
  value       = yandex_kubernetes_cluster.this.name
}

output "cluster_endpoint" {
  description = "Публичный endpoint API Kubernetes."
  value       = yandex_kubernetes_cluster.this.master[0].external_v4_endpoint
}

output "cluster_ca_certificate" {
  description = "CA-сертификат кластера."
  value       = yandex_kubernetes_cluster.this.master[0].cluster_ca_certificate
  sensitive   = true
}

output "node_group_id" {
  description = "Идентификатор группы узлов."
  value       = yandex_kubernetes_node_group.workers.id
}

output "vpc_network_id" {
  description = "Идентификатор облачной сети стенда."
  value       = yandex_vpc_network.this.id
}

output "subnet_ids" {
  description = "Подсети узлов по зонам доступности."
  value       = { for zone, subnet in yandex_vpc_subnet.nodes : zone => subnet.id }
}

output "get_credentials_command" {
  description = "Команда для получения kubeconfig."
  value       = "yc managed-kubernetes cluster get-credentials --id ${yandex_kubernetes_cluster.this.id} --external --force"
}
