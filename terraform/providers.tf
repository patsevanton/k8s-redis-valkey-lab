# Авторизация берётся из окружения или профиля yc:
#   export YC_TOKEN=$(yc iam create-token)
#   export YC_CLOUD_ID=$(yc config get cloud-id)
#   export YC_FOLDER_ID=$(yc config get folder-id)
provider "yandex" {}

data "yandex_client_config" "current" {}

locals {
  folder_id = coalesce(var.folder_id, data.yandex_client_config.current.folder_id)
}
