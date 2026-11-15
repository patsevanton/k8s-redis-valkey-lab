variable "folder_id" {
  description = "Каталог Yandex Cloud. Если не задан, берётся из профиля yc / YC_FOLDER_ID."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Имя кластера Managed Service for Kubernetes и префикс для остальных ресурсов."
  type        = string
  default     = "redis-valkey-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,61}[a-z0-9]$", var.cluster_name))
    error_message = "Имя должно состоять из строчных латинских букв, цифр и дефисов, начинаться с буквы и быть длиной 3-63 символа."
  }
}

variable "zone" {
  description = "Зона доступности мастер-узла. rc1b в стенде не используется, rc1c выведена из эксплуатации; допустимы ru-central1-a, -d, -e и -f."
  type        = string
  default     = "ru-central1-d"

  validation {
    condition     = contains(["ru-central1-a", "ru-central1-d", "ru-central1-e", "ru-central1-f"], var.zone)
    error_message = "Допустимы только ru-central1-a, ru-central1-d, ru-central1-e и ru-central1-f."
  }
}

# Порядок зон задаёт и CIDR подсетей (index + 1), поэтому ru-central1-d и
# ru-central1-a оставлены на своих местах: иначе подсети пересоздадутся.
variable "node_zones" {
  description = "Зоны доступности для групп узлов. Три зоны дают по узлу в каждой и проверку отказа любой зоны."
  type        = list(string)
  default     = ["ru-central1-d", "ru-central1-a", "ru-central1-e"]

  validation {
    condition     = length(var.node_zones) > 0 && alltrue([for z in var.node_zones : contains(["ru-central1-a", "ru-central1-d", "ru-central1-e", "ru-central1-f"], z)])
    error_message = "Перечислите зоны из набора ru-central1-a, -d, -e, -f."
  }
}

variable "kubernetes_version" {
  description = "Версия Kubernetes для мастера и узлов. Актуальные версии: yc managed-kubernetes list-versions."
  type        = string
  default     = "1.35"
}

variable "release_channel" {
  description = "Релизный канал Kubernetes: STABLE, REGULAR или RAPID."
  type        = string
  default     = "STABLE"

  validation {
    condition     = contains(["STABLE", "REGULAR", "RAPID"], var.release_channel)
    error_message = "Допустимые каналы: STABLE, REGULAR, RAPID."
  }
}

variable "network_cidr" {
  description = "CIDR облачной сети. Подсети узлов нарезаются из него по /24."
  type        = string
  default     = "10.10.0.0/16"
}

variable "cluster_ipv4_range" {
  description = "CIDR подов. Не должен пересекаться с сетью и сервисным диапазоном."
  type        = string
  default     = "10.112.0.0/16"
}

variable "service_ipv4_range" {
  description = "CIDR сервисов Kubernetes."
  type        = string
  default     = "10.96.0.0/16"
}

variable "admin_cidrs" {
  description = "Адреса, с которых доступен Kubernetes API. Для стенда по умолчанию весь интернет — сузьте до своего IP."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allow_ssh_from_admin" {
  description = "Открыть SSH (TCP 22) на узлы с адресов admin_cidrs."
  type        = bool
  default     = false
}

variable "node_count" {
  description = "Число узлов. Для проверки отказа зоны нужно минимум 3–4."
  type        = number
  default     = 3

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 10
    error_message = "Допустимое число узлов — от 1 до 10."
  }
}

variable "node_platform_id" {
  description = "Платформа узлов."
  type        = string
  default     = "standard-v3"
}

variable "node_cores" {
  description = "vCPU на узел."
  type        = number
  default     = 2
}

variable "node_memory" {
  description = "Память узла в ГБ. На 4 ГБ все пять вариантов занимают 78–91% запрошенной памяти узлов, и замене пода не хватает места (Insufficient memory), поэтому по умолчанию 8 ГБ. Для standard-v3 при 2 vCPU это максимум (8 ГБ на ядро)."
  type        = number
  default     = 8
}

variable "node_disk_type" {
  description = "Тип загрузочного диска: network-ssd или network-hdd."
  type        = string
  default     = "network-ssd"
}

variable "node_disk_size" {
  description = "Размер загрузочного диска узла в ГБ."
  type        = number
  default     = 32
}

variable "node_preemptible" {
  description = "Прерываемые узлы дешевле, но внеплановое выключение мешает замерам отказоустойчивости."
  type        = bool
  default     = false
}

variable "master_public_ip" {
  description = "Публичный IP мастера для kubectl с рабочей станции."
  type        = bool
  default     = true
}

variable "master_auto_upgrade" {
  description = "Автообновление мастера. Для воспроизводимых замеров выключено."
  type        = bool
  default     = false
}

variable "node_auto_upgrade" {
  description = "Автообновление узлов."
  type        = bool
  default     = false
}

variable "maintenance_start_time" {
  description = "Начало окна обслуживания в UTC, формат HH:MM."
  type        = string
  default     = "03:00"
}

variable "maintenance_duration" {
  description = "Длительность окна обслуживания, например 3h."
  type        = string
  default     = "3h"
}

variable "labels" {
  description = "Метки, которые добавляются к кластеру и группе узлов."
  type        = map(string)
  default = {
    project = "redis-valkey-lab"
    owner   = "terraform"
  }
}
