# k8s-redis-valkey-lab

Стенд для сравнения Redis и Valkey в Kubernetes. Terraform поднимает управляемый кластер в Yandex Cloud, Helm-значения и CR-манифесты разворачивают пять вариантов: три Helm-чарта и два оператора. Дальше на одном и том же железе можно сравнивать функциональность, поведение при отказе, потребление ресурсов и актуальность версий.

Инфраструктура: зональный мастер Kubernetes 1.35 в `ru-central1-d`, три узла 2 vCPU / 4 ГБ в `ru-central1-d` и `ru-central1-a`, сеть `10.10.0.0/16`, Calico, мастер-логи в Cloud Logging.

## Что разворачивается

| Вариант | Способ | Топология | Версия на 2026-11-14 |
|---|---|---|---|
| `redis-groundhog2k` | Helm, community-чарт groundhog2k | 3 пода Redis + Sentinel-сайдкар | Redis 8.10.3 |
| `redis-cloudpirates` | Helm, community-чарт CloudPirates | 3 пода Redis + Sentinel-сайдкар | Redis 8.10.3 |
| `valkey-official` | Helm, valkey-io | 3 пода Valkey + 3 отдельных Sentinel | Valkey 9.1.3 |
| `redis-operator` | Оператор OT-CONTAINER-KIT | 3 шарда × 1 реплика, 6 подов | Redis 8.10.1 |
| `valkey-operator` | Оператор valkey-io | 3 шарда × 1 реплика, 6 подов | Valkey 9.1.3 |

Все образы закреплены тегом или digest — плавающих `latest` нет. Redis 8.10.3 и Valkey 9.1.3 — последние стабильные релизы upstream на дату замера. Расхождения по вине вендоров: чарт CloudPirates несёт appVersion 8.10.2 (образ в values поднят до 8.10.3), у оператора OT последний собранный образ `v8.10.1` — на два патча позже upstream.

Bitnami-чарты в стенд сознательно не входят: их образы публикуются только как `latest`, без неизменяемых версий в основном репозитории.

## Требования

- Авторизованный `yc` CLI и права создавать сеть, кластер Kubernetes, сервисные аккаунты и IAM-привязки в каталоге.
- Terraform 1.5+.
- `kubectl` и Helm 3.8+ (для OCI-чартов).
- Квоты Yandex Cloud на 3–4 узла и один мастер Kubernetes.

## Быстрый старт

```bash
export YC_TOKEN=$(yc iam create-token)
export YC_CLOUD_ID=$(yc config get cloud-id)
export YC_FOLDER_ID=$(yc config get folder-id)

cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

`terraform.tfvars` уже в `.gitignore`: там может оказаться `folder_id` и ваш домашний адрес. Перед применением сузьте `admin_cidrs` до своего IP — по умолчанию Kubernetes API открыт всему интернету.

Kubeconfig:

```bash
yc managed-kubernetes cluster get-credentials \
  --id "$(terraform -chdir=terraform output -raw cluster_id)" \
  --external --force
kubectl get nodes -o wide
```

Узлы должны распределиться по двум зонам. Мастер зональный: падение `ru-central1-d` уносит control plane, поэтому стенд проверяет отказоустойчивость данных и подов, а не мастера.

## Установка вариантов

Рабочие нагрузки кладутся в namespace `redis-valkey-lab`:

```bash
kubectl create namespace redis-valkey-lab
```

### Helm: Redis, чарт groundhog2k

```bash
helm repo add groundhog2k https://groundhog2k.github.io/helm-charts
helm repo update
helm install redis-groundhog2k groundhog2k/redis \
  --version 2.4.9 -n redis-valkey-lab \
  -f helm/redis-groundhog2k/values.yaml
```

### Helm: Redis, чарт CloudPirates

```bash
helm install redis-cloudpirates \
  oci://registry-1.docker.io/cloudpirates/redis \
  --version 0.39.0 -n redis-valkey-lab \
  -f helm/redis-cloudpirates/values.yaml
```

### Helm: официальный Valkey

```bash
helm repo add valkey https://valkey.io/valkey-helm
helm repo update
helm install valkey-official valkey/valkey \
  --version 1.0.0 -n redis-valkey-lab \
  -f helm/valkey-official/values.yaml
```

### Оператор Redis (OT-CONTAINER-KIT)

```bash
helm repo add ot-container-kit https://ot-container-kit.github.io/helm-charts
helm repo update
helm install redis-operator ot-container-kit/redis-operator \
  --version 0.27.0 -n redis-operator --create-namespace \
  -f helm/redis-operator/values.yaml

kubectl apply -f operators/redis/redis-cluster.yaml
```

### Оператор Valkey (valkey-io)

```bash
helm repo add valkey https://valkey.io/valkey-helm
helm repo update
helm install valkey-operator valkey/valkey-operator \
  --version 0.9.0 -n valkey-operator --create-namespace \
  -f helm/valkey-operator/values.yaml

kubectl apply -f operators/valkey/valkey-cluster.yaml
```

Одновременно все пять вариантов на трёх узлах не поместятся. Запускайте по одному-два и удаляйте предыдущие, либо увеличьте `node_count` до 4–5.

## Сценарии сравнения

### Функциональность и версия

```bash
# Версия сервера
kubectl exec -n redis-valkey-lab redis-groundhog2k-0 -c redis-server -- redis-server --version
kubectl exec -n redis-valkey-lab redis-cloudpirates-0 -c redis -- redis-server --version
kubectl exec -n redis-valkey-lab valkey-official-0 -c valkey -- valkey-server --version

# Базовые команды и TTL
kubectl exec -n redis-valkey-lab redis-cloudpirates-0 -c redis -- \
  redis-cli SET lab:key value EX 60
kubectl exec -n redis-valkey-lab redis-cloudpirates-0 -c redis -- redis-cli TTL lab:key

# Модули: у Redis 8 в образе есть JSON/Search, у Valkey — только то, что собрано в образе
kubectl exec -n redis-valkey-lab redis-cloudpirates-0 -c redis -- redis-cli MODULE LIST
kubectl exec -n redis-valkey-lab valkey-official-0 -c valkey -- valkey-cli MODULE LIST

# Sentinel
kubectl exec -n redis-valkey-lab redis-groundhog2k-0 -c redis-sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name redisha
kubectl exec -n redis-valkey-lab redis-cloudpirates-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# Кластерный режим у операторов.
# У valkey-operator имя пода выдаёт сам оператор в status.podName ValkeyNode.
kubectl exec -n redis-valkey-lab redis-cluster-leader-0 -- redis-cli CLUSTER INFO
kubectl exec -n redis-valkey-lab \
  "$(kubectl get valkeynode -n redis-valkey-lab -o jsonpath='{.items[0].status.podName}')" \
  -- valkey-cli CLUSTER INFO
```

Имена подов и контейнеров, на которые опираются команды: `redis-groundhog2k-0` (`redis-server`, `redis-sentinel`), `redis-cloudpirates-0` (`redis`, `sentinel`), `valkey-official-0` (`valkey`), `redis-cluster-leader-0` у оператора OT. У valkey-operator каждый узел получает свой StatefulSet `valkey-<имя>-<шард>-<номер>`, поэтому имя пода смотрите в `status.podName`.

Обратите внимание: у groundhog2k мастер-группа Sentinel называется `redisha`, у CloudPirates и официального чарта Valkey — `mymaster`. Это важно для клиентского дискавери.

Сравнивайте одинаковые команды на одинаковых данных: `SET/GET`, `HSET`, `XADD`, TTL, ACL, `INFO memory`, `INFO commandstats`, поведение `SCAN` и кластерных слотов.

### Отказоустойчивость

Сценарии выполняет человек: удаление подов и узлов — это изменение кластера, а не read-only операция.

1. **Отказ мастера.** Удалить под текущего мастера и замерить время до появления нового:
   ```bash
   # Sentinel: узнать, кто сейчас мастер
   kubectl exec -n redis-valkey-lab redis-cloudpirates-0 -c sentinel -- \
     redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
   # Кластер: узнать лидера шарда 0
   kubectl exec -n redis-valkey-lab redis-cluster-leader-0 -- \
     redis-cli CLUSTER NODES | grep master
   kubectl delete pod -n redis-valkey-lab <под-мастера> --wait=false
   kubectl get pods -n redis-valkey-lab -w
   ```
   Для Sentinel — снова опросить `SENTINEL get-master-addr-by-name`, для кластера — `CLUSTER SHARDS`/`CLUSTER INFO`.

2. **Потеря данных.** До отказа непрерывно писать ключи с монотонным счётчиком, после — проверить максимальный ключ. При `appendfsync everysec` допустима потеря примерно до секунды записей; сравните Redis и Valkey на одинаковой нагрузке.

3. **Отказ узла.** Удалить один узел группы через `yc managed-kubernetes node-group delete-node` или остановить его в консоли, затем проверить, что поды переехали, а кворум Sentinel (2 из 3) сохранился. Для чистого замера зоны удаляйте все узлы одной зоны.

4. **Отказ зоны.** Погасить узлы в `ru-central1-a` и убедиться, что вариант пережил потерю зоны. У Sentinel-вариантов три пода и две зоны, поэтому кворум 2 из 3 выживает, только если в уцелевшей зоне оказались минимум два пода: `topologySpreadConstraints` в values разложат их 2/1, но какая зона получит два пода — не гарантировано. Кластерные варианты при потере зоны теряют шарды, чьи мастер и реплика оказались в одной зоне.

5. **Плановое обслуживание.** `kubectl drain` узла: проверьте PDB, время переезда и потерю данных. Бюджет `maxUnavailable: 1` задан у всех пяти вариантов: в чартах groundhog2k и CloudPirates и в CR оператора OT мы включаем его в values (там по умолчанию его нет), официальный чарт Valkey тоже требует явного включения, а valkey-operator создаёт PDB сам в режиме `Cluster`.

### Актуальность версий

Фиксируйте в таблице: версию сервера из `INFO server`, версию чарта (`helm list`), дату релиза образа и дату последнего коммита оператора. Отдельно отметьте, как быстро вендор подтягивает CVE и новые мажорные версии.

## Ограничения стенда

- **`rc1b` недоступна.** Все ресурсы создаются только в `ru-central1-d` и `ru-central1-a`. Региональный мастер требует трёх зон `ru-central1`, поэтому здесь используется зональный.
- **Master не HA.** Падение зоны с мастером остановит API. Это осознанный компромисс по цене; отказоустойчивость данных проверяется на уровне подов и узлов.
- **У Redis нет официального Helm-чарта.** Redis в Helm представлен только community-чартами (в стенде — groundhog2k и CloudPirates), тогда как Valkey публикует официальный чарт. Это часть сравнения: у Valkey выше уровень поддержки в Kubernetes.
- **Разная цена Sentinel.** У groundhog2k, CloudPirates и официального чарта Valkey Sentinel — сайдкар в поде с данными (3 пода), у оператора Valkey и OT кластерный режим без Sentinel (6 подов). Сравнивайте не только задержку failover, но и накладные расходы.
- **Valkey Operator молодой.** CRD `v1alpha1`, поддерживается только кластерный режим; standalone и Sentinel не заявлены. Для production оператор пока не рекомендован.
- **Расхождение версий у вендоров.** Образ OT-оператора `quay.io/opstree/redis:v8.10.1` отстаёт от upstream 8.10.3 на два патча; чарт CloudPirates несёт appVersion 8.10.2, образ в values поднят до 8.10.3 отдельно. Так выглядит реальная скорость обновления упаковок, и это тоже результат замера.
- **Digest-фиксация только у CloudPirates.** groundhog2k и официальный чарт Valkey фиксируют версию тегом, CloudPirates — тегом и digest. Для воспроизводимых замеров сверяйте digest через `kubectl get pod -o jsonpath='{.spec.containers[*].image}'`.
- **Публичные IP.** Узлы выходят в интернет через свой публичный IP (`nat = true`), чтобы тянуть образы с Docker Hub и ghcr.io. Если политика запрещает публичные IP у узлов, замените это на egress-gateway.
- **Состояние Terraform локальное.** `terraform.tfstate` и `terraform.tfvars` не коммитятся. Для командной работы добавьте S3-backend.

## Какие проекты не тестируются и почему

Просмотрены чарты и операторы Redis и Valkey из ArtifactHub и GitHub, которые ставятся на обычный Kubernetes. Отбор механический: вне охвата — Bitnami и форки на его образах, репозиторий в архиве и проекты без коммитов 12 месяцев. Блокером считаются только два случая: нельзя закрепить образ (зашит `latest`) и нельзя установить (несовместимость с Kubernetes 1.35 или коммерческая лицензия).

| Причина | Кто | Что именно |
|---|---|---|
| Bitnami и его форки | [bitnami/containers](https://github.com/bitnami/containers), [cowboysysop/charts](https://github.com/cowboysysop/charts) и ещё около 20 форков | В репозитории Bitnami образы публикуются только как `latest`; неизменяемые версии перенесены в `bitnamilegacy`, но это те же образы |
| Репозиторий в архиве | [spotahome/redis-operator](https://github.com/spotahome/redis-operator) (1666★), [Kagiso-me/charts](https://github.com/Kagiso-me/charts) | Правки некуда отправить: автор их не принимает, проект не развивается |
| Нет коммитов 12 месяцев | [tongdun/td-redis-operator](https://github.com/tongdun/td-redis-operator) (2023-12-01), [ucloud/redis-cluster-operator](https://github.com/ucloud/redis-cluster-operator) (2023-11-02), `ucloud/redis-operator` (2022-12-27), [AmadeusITGroup/Redis-Operator](https://github.com/AmadeusITGroup/Redis-Operator) (2021-03-25), `amaizfinance/redis-operator` (2022-08-23), `PayU/redis-operator` (2023-07-07), [magefleet/helm-chart-redis](https://github.com/magefleet/helm-chart-redis) (2025-11-09) | Последний коммит старше 12 месяцев на дату замера, то есть чарт или оператор не догоняет ни версии Redis, ни версии Kubernetes |
| Не чарт и не оператор для обычного кластера | [opensuse-valkey](https://build.opensuse.org/package/show/openSUSE:Factory/valkey-image), [canonical/redis-k8s-operator](https://github.com/canonical/redis-k8s-operator) | У первого запись на ArtifactHub ведёт на OBS-пакет образа, второй — Juju-чарм; `helm install` и `kubectl apply` для них не работают |
| Не ставится на Kubernetes 1.35 | [DataDog/redis-cluster-kubernetes-operator](https://github.com/DataDog/redis-cluster-kubernetes-operator/blob/main/Chart.yaml) | В чарте `kubeVersion` разрешает только 1.33 и 1.36, кластер 1.35 не проходит проверку ещё до установки |
| Коммерческая лицензия или платформа | [KubeDB](https://kubedb.com/docs/latest/setup/), Redis Enterprise, платформенные каталоги (OpenShift OperatorHub, Nutanix, VMware VKS) | Оператор и образы требуют подписки либо ставятся только внутри своей платформы; в обычном кластере Yandex Cloud такой вариант не воспроизвести |

Ошибка в чарте проект не исключает: если автор принимает исправление, вариант попадает в стенд. Такого исправления сейчас ждут три варианта. У [start-codex/valkey-helm-chart](https://github.com/start-codex/valkey-helm-chart/blob/main/values.yaml) зашит `tag: "latest"` для образа Chainguard — нужен пин по digest или переход на `valkey/valkey` с тегом. В [SAP/redis-operator](https://github.com/SAP/redis-operator/blob/main/pkg/operator/data/charts/redis/values.yaml) и [SAP/valkey-operator](https://github.com/SAP/valkey-operator/blob/main/pkg/operator/data/charts/valkey/values.yaml) встроенные чарты несут `bitnami/redis:7.2.5` и `bitnami/valkey:8.1.2` — нужна возможность переопределить образ в CR, иначе правило «без Bitnami» не выполнить.

Остальные дефекты — отсутствие PDB, standalone вместо репликации, отсутствие Sentinel — к исключению не приводят. Такие варианты тестируются как есть: их поведение при `drain` и отказе и есть результат сравнения, а не причина вычеркнуть проект.

Граница проходит по коммитам, а не по релизам. [hyperspike/valkey-operator](https://github.com/hyperspike/valkey-operator) не выпускал релиз с 2025-10-12, но коммиты свежие (2026-04-16) — он в охвате. `magefleet/helm-chart-redis` с последним коммитом 2025-11-09 — уже нет. [alauda/redis-operator](https://github.com/alauda/redis-operator) релизов не публикует вообще, но коммиты свежие, поэтому он в охвате и ставится из репозитория.

Из 32 вариантов отбора (20 чартов и 12 операторов) 29 тестируются сразу, 3 ждут исправления. В репозитории пока собраны пять вариантов: остальные добавляются по мере подготовки манифестов, по одному-два за прогон.

## Структура репозитория

```text
.
├── terraform/                 # VPC, подсети, security groups, IAM, кластер, node group
│   ├── versions.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── network.tf
│   ├── iam.tf
│   ├── kubernetes.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── helm/
│   ├── redis-groundhog2k/     # values для Redis 8.10.3 + Sentinel-сайдкар
│   ├── redis-cloudpirates/    # values для Redis 8.10.3 + Sentinel-сайдкар
│   ├── valkey-official/       # values для официального чарта
│   ├── redis-operator/        # values для OT-CONTAINER-KIT
│   └── valkey-operator/       # values для valkey-io
└── operators/
    ├── redis/redis-cluster.yaml
    └── valkey/valkey-cluster.yaml
```

## Удаление

```bash
helm uninstall redis-groundhog2k redis-cloudpirates valkey-official -n redis-valkey-lab 2>/dev/null
helm uninstall redis-operator -n redis-operator 2>/dev/null
helm uninstall valkey-operator -n valkey-operator 2>/dev/null
kubectl delete namespace redis-valkey-lab

cd terraform
terraform destroy
```

PVC и диски, созданные CSI-драйвером, могут остаться после удаления namespace. Проверьте `kubectl get pv` и `yc compute disk list` перед `terraform destroy`. У чарта CloudPirates есть отдельный флаг `persistence.keepPvc`, у groundhog2k — `storage.keepPvc`: по умолчанию PVC удаляются вместе с релизом.

## Источники

- Поддерживаемые версии Kubernetes в Yandex Cloud: <https://yandex.cloud/ru/docs/managed-kubernetes/concepts/k8s-supported-versions>
- Рекомендации по группам безопасности кластера: <https://yandex.cloud/ru/docs/managed-kubernetes/operations/connect/security-groups>
- Создание кластера и сервисных аккаунтов: <https://yandex.cloud/ru/docs/managed-kubernetes/operations/kubernetes-cluster/kubernetes-cluster-create>
- Релизы Redis: <https://github.com/redis/redis/releases>
- Релизы Valkey: <https://github.com/valkey-io/valkey/releases>
- Чарт groundhog2k: <https://github.com/groundhog2k/helm-charts>
- Чарт CloudPirates: <https://github.com/CloudPirates-io/helm-charts>
- Официальные чарты Valkey: <https://github.com/valkey-io/valkey-helm>
- Valkey Operator: <https://github.com/valkey-io/valkey-operator>
- Redis Operator OT-CONTAINER-KIT: <https://github.com/OT-CONTAINER-KIT/redis-operator>
- Официальный образ Redis: <https://hub.docker.com/_/redis>
