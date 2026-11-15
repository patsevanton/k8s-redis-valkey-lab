# k8s-redis-valkey-lab

Стенд для сравнения Redis и Valkey в Kubernetes. Terraform поднимает управляемый кластер в Yandex Cloud, Helm-значения и CR-манифесты разворачивают пять вариантов: три Helm-чарта и два оператора. Дальше на одном и том же железе можно сравнивать функциональность, поведение при отказе, потребление ресурсов и актуальность версий.

Инфраструктура: зональный мастер Kubernetes 1.35 в `ru-central1-d`, три узла 2 vCPU / 8 ГБ по одному в `ru-central1-d`, `ru-central1-a` и `ru-central1-e`, сеть `10.10.0.0/16`, Cilium в туннельном режиме VxLAN (он же CNI кластера). Замеры ниже сделаны на узлах 2 vCPU / 4 ГБ — там память была узким местом, из-за чего `node_memory` по умолчанию поднят до 8 ГБ.

## Что разворачивается

Пять вариантов делятся на два семейства. В первом (три Helm-чарта) данные реплицируются, а мастера выбирает Sentinel: у groundhog2k и CloudPirates он запущен сайдкаром в поде с данными, у официального чарта Valkey — отдельными подами. Во втором (два оператора) Sentinel нет вообще: это кластерный режим, где три шарда разложены по узлам, а отказоустойчивость даёт реплика внутри шарда. Поэтому «3 шарда × 1 реплика, 6 подов» у операторов означает 3 мастера и 3 реплики, а не шесть экземпляров Sentinel.

| Вариант | Способ | Режим | Поды с данными | Поды Sentinel | Всего подов | Версия на 2026-11-14 |
|---|---|---|---|---|---|---|
| `redis-groundhog2k` | Helm, community-чарт groundhog2k | репликация + Sentinel | 3 (1 мастер + 2 реплики) | 0 отдельных, сайдкар в каждом поде | 3 | Redis 8.10.3 |
| `redis-cloudpirates` | Helm, community-чарт CloudPirates | репликация + Sentinel | 3 (1 мастер + 2 реплики) | 0 отдельных, сайдкар в каждом поде | 3 | Redis 8.10.3 |
| `valkey-official` | Helm, valkey-io | репликация + Sentinel | 3 (1 мастер + 2 реплики) | 3 отдельных пода | 6 | Valkey 9.1.3 |
| `redis-operator` | Оператор OT-CONTAINER-KIT | Redis Cluster | 6 (3 шарда × 1 реплика) | нет | 6 | Redis 8.10.1 |
| `valkey-operator` | Оператор valkey-io | Valkey Cluster | 6 (3 шарда × 1 реплика) | нет | 6 | Valkey 9.1.3 |

Всего подов — это поды с данными и Sentinel. Поды контроллеров операторов в подсчёт не входят: `redis-operator` и `valkey-operator` добавляют по одному поду в свои namespace. Все пять вариантов вместе — 24 таких пода плюс 2 контроллера. На узлах 2 vCPU / 4 ГБ, где шли замеры, они помещаются только за счёт скромных `requests`: запрошено 88%, 91% и 78% памяти узлов (`rc1a`, `rc1d`, `rc1e`), при этом `limits` переподписаны до 409% CPU и 294% памяти. Поэтому по умолчанию в `variables.tf` стоит 8 ГБ на узел: на 4 ГБ свободной памяти остаётся всего 235–321 Mi, а поду с данными и Sentinel нужно 320 Mi, и планировщик отвечает `Insufficient memory`. Это снимает нехватку памяти, но не чинит отказ зоны: под с зональным PVC всё равно ждёт свой узел. Для нагрузочных сценариев запускайте по одному-два варианта.

### Состав подов

| Вариант | Поды | Контейнеры | Sentinel: экземпляры / кворум / группа | PVC | PDB |
|---|---|---|---|---|---|
| `redis-groundhog2k` | `redis-groundhog2k-0..2` | `redis-server` + `redis-sentinel` | 3 / 2 из 3 / `redisha` | 1 Gi на под | `maxUnavailable: 1`, включается в values |
| `redis-cloudpirates` | `redis-cloudpirates-0..2` | `redis` + `sentinel` | 3 / 2 из 3 / `mymaster` | 1 Gi на под | `maxUnavailable: 1`, включается в values |
| `valkey-official` | 3 пода данных + 3 отдельных пода Sentinel | `valkey` в поде данных, Sentinel — в своём поде | 3 / 2 из 3 / `mymaster` | 1 Gi на под данных, у Sentinel нет | два PDB по `maxUnavailable: 1` |
| `redis-operator` | `redis-cluster-leader-0..2` и `redis-cluster-follower-0..2` | один контейнер | нет | 1 Gi на под | два PDB по `maxUnavailable: 1` |
| `valkey-operator` | свой StatefulSet на каждый узел, имя пода в `status.podName` | один контейнер | нет | 1 Gi на под | создаётся оператором автоматически |

HAProxy в официальном чарте Valkey выключен: при включении он добавит отдельные поды, и «6 подов» перестанет быть верным. У Sentinel-вариантов PVC получают только поды с данными.

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

Узлы должны распределиться по трём зонам, по одному в каждой. Мастер зональный: падение `ru-central1-d` уносит control plane, поэтому стенд проверяет отказоустойчивость данных и подов, а не мастера.

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

Все пять вариантов на трёх узлах помещаются — 24 пода с данными и Sentinel плюс два контроллера операторов. На узлах 2 vCPU / 4 ГБ, где шли замеры, запас по памяти почти исчерпан: запрошено 88%, 91% и 78%, а `limits` переподписаны втрое-вчетверо, поэтому по умолчанию теперь 8 ГБ (`node_memory`); изменение этого параметра пересоздаёт узлы группы. Для сценариев с нагрузкой и для отказа зоны запускайте по одному-два варианта и удаляйте предыдущие, либо увеличьте `node_count` до 4–5. Поды с зональными PVC при отказе зоны никуда не переезжают: диск привязан к зоне, поэтому пересозданный под остаётся `Pending`, пока узел не вернётся.

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

# Модули. В официальном образе `redis` из Redis 8 есть только vectorset:
# JSON, Search, Bloom и прочие модули лежат в отдельном образе redis-stack,
# а не в `redis`. У Valkey в образе модуль lua.
kubectl exec -n redis-valkey-lab redis-cloudpirates-0 -c redis -- redis-cli MODULE LIST
kubectl exec -n redis-valkey-lab valkey-official-0 -c valkey -- valkey-cli MODULE LIST

# Sentinel
kubectl exec -n redis-valkey-lab redis-groundhog2k-0 -c redis-sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name redisha
kubectl exec -n redis-valkey-lab redis-cloudpirates-0 -c sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
# У официального чарта Valkey Sentinel всегда закрыт отдельным паролем
# (sentinel.password в values), и запросы идут под ACL-пользователем sentinel.
kubectl exec -n redis-valkey-lab valkey-official-sentinel-0 -- \
  sh -c 'REDISCLI_AUTH=lab-sentinel-change-me valkey-cli --user sentinel -p 26379 \
    SENTINEL get-master-addr-by-name mymaster'

# Кластерный режим у операторов.
# У valkey-operator имя пода выдаёт сам оператор в status.podName ValkeyNode.
kubectl exec -n redis-valkey-lab redis-cluster-leader-0 -- redis-cli CLUSTER INFO
kubectl exec -n redis-valkey-lab \
  "$(kubectl get valkeynode -n redis-valkey-lab -o jsonpath='{.items[0].status.podName}')" \
  -- valkey-cli CLUSTER INFO
```

Имена подов и контейнеров, на которые опираются команды: `redis-groundhog2k-0` (`redis-server`, `redis-sentinel`), `redis-cloudpirates-0` (`redis`, `sentinel`), `valkey-official-0` (`valkey`), `redis-cluster-leader-0` у оператора OT. У valkey-operator каждый узел получает свой StatefulSet `valkey-<имя>-<шард>-<номер>`, поэтому имя пода смотрите в `status.podName`.

У подов valkey-operator контейнер называется `server`, а в окружение оператор кладёт `VALKEYCLI_AUTH`/`PRIMARY_AUTH`. Из-за этого каждый вызов `valkey-cli` печатает `AUTH failed: ERR AUTH <password> called without any password configured`, хотя команда выполняется и ответ приходит. Это шум, а не отказ.

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

3. **Отказ узла.** Удалить один узел группы через `yc managed-kubernetes node-group delete-node` или остановить его в консоли, затем проверить, что поды вернулись, а кворум Sentinel (2 из 3) сохранился. При `node_count = 3` в каждой зоне по одному узлу, поэтому отказ узла совпадает с отказом зоны.

4. **Отказ зоны.** Остановить узел одной из зон (например, `ru-central1-a`) и убедиться, что вариант пережил потерю зоны. Разложение по зонам задают `topologySpreadConstraints` с `whenUnsatisfiable: ScheduleAnyway` — ограничение мягкое: при нехватке памяти под уходит туда, где есть место, даже если ровный расклад по зонам нарушается. На замере с пятью вариантами одновременно поды разложились 7/8/9 по зонам, а у `redis-groundhog2k` и `redis-cloudpirates` вышло 2/1/0 — у первого пустой осталась `rc1d`, у второго `rc1a`. Кворум 2 из 3 в таком раскладе переживает потерю одной зоны, но не той, где стоят два пода из трёх. Кластерные варианты теряют шарды, чьи мастер и реплика оказались в одной зоне, а если в отказавшей зоне были два мастера из трёх, выборы не набирают кворум и весь кластер уходит в `cluster_state:fail`.

5. **Плановое обслуживание.** `kubectl drain` узла: проверьте PDB, время переезда и потерю данных. Бюджет `maxUnavailable: 1` задан у всех пяти вариантов: в чартах groundhog2k и CloudPirates и в CR оператора OT мы включаем его в values (там по умолчанию его нет), официальный чарт Valkey тоже требует явного включения, а valkey-operator создаёт PDB сам в режиме `Cluster`.

### Замер failover мастера (2026-11-15)

Первый прогон — на стенде с двумя зонами, пять вариантов одновременно на трёх узлах; у каждого удалялся под текущего мастера. Время — от `kubectl delete pod` до появления нового мастера и до первой успешной записи в него (прочерк — запись отдельно не замерялась). Потерю записей этот прогон не проверял, для неё нужен непрерывный поток записи по сценарию 2.

| Вариант | Новый мастер | Запись | Механизм переключения |
|---|---|---|---|
| `redis-groundhog2k` | 8 c | — | нет preStop, срабатывает `down-after-milliseconds: 5000` и выборы Sentinel |
| `redis-cloudpirates` | 3–4 c | — | preStop-хук `prestop.sh` инициирует failover до остановки контейнера |
| `valkey-official` | 3 c | 5 c | preStop-хук `sentinel-prestop.sh` |
| `redis-operator` (OT) | 5 c | 5 c | preStop `cluster failover` на реплику с максимальным offset |
| `valkey-operator` | 7 c | 9 c | preStop нет; замер с `--force --grace-period=0` |

Разница объясняется не скоростью Redis или Valkey, а упаковкой. Где есть preStop-хук, мастерство передаётся до остановки контейнера: 3–5 c. У valkey-operator своего хука нет — мастерство передаёт сам сервер, поэтому время зависит от того, успевает ли он это сделать до остановки контейнера: в первом прогоне 7–9 c, во втором 2–4 c (разбор ниже). У groundhog2k хуков нет вообще, и время равно детекции Sentinel `down-after-milliseconds: 5000` плюс выборы: 8 c. У CloudPirates хук висит на обоих контейнерах (`prestop.sh` и `prestop-sentinel.sh`).

Отдельный результат — **реанимация пода у оператора OT**. Переключение на реплику проходит за 5 c, но пересозданный под не возвращается в кластер. Причина в том, что `/etc/redis/redis.conf` задаёт `cluster-config-file /node-conf/nodes.conf`, а `storage.nodeConfVolume` в CR выключен: `/node-conf` — не том, а каталог внутри контейнера, поэтому после пересоздания пода он пустой. В логах видно `No cluster configuration found, I'm …` и `sed: /node-conf/nodes.conf: No such file or directory`: узел стартует одиночным мастером (`cluster_known_nodes:1`) с нулём или одним слотом из прежней карты. Остальные узлы видят старую запись этого пода как `fail`, а новый под в кластер не попадает, и оператор раз в минуту безуспешно пытается выполнить `redis-cli --cluster create`, логируя `Node ... is not empty` (подробности — в [OT-CONTAINER-KIT/redis-operator#1978](https://github.com/OT-CONTAINER-KIT/redis-operator/issues/1978)). Итог: шард деградирует — живёт без реплики или теряет мастера — и сам не восстанавливается.

Удаление PVC не помогает: `nodes.conf` лежит не на нём, а в локальном каталоге контейнера. Штатный путь — включить `storage.nodeConfVolume: true`, чтобы конфигурация кластера переживала пересоздание пода (объяснение флага — в [обсуждении #871](https://github.com/OT-CONTAINER-KIT/redis-operator/discussions/871)); в этом стенде флаг выключен, и такое лечение не проверялось.

`valkey-operator` ту же ситуацию переживает штатно: реплика становится primary, пересозданный под догоняет её как replica, CR возвращается в `Ready`.

### Повторный замер failover на трёхзональном стенде (2026-11-15)

Тот же сценарий на кластере с тремя зонами (`rc1a`, `rc1d`, `rc1e`) и всеми пятью вариантами одновременно. Время — от `kubectl delete pod` мастера до появления нового мастера и до первой успешной записи.

| Вариант | Новый мастер | Запись | Механизм переключения |
|---|---|---|---|
| `redis-groundhog2k` | 8,4 c | 10,8 c | без preStop: `down-after-milliseconds: 5000` и выборы Sentinel |
| `redis-cloudpirates` | 2,4 c | 3,7 c | preStop `prestop.sh` |
| `valkey-official` | 2,4 c | 3,7 c | preStop `sentinel-prestop.sh` |
| `redis-operator` (OT) | 2,3 c | 4,6 c | preStop `cluster failover` на реплику с максимальным offset |
| `valkey-operator` | 1,9–4,0 c | 3,8 c | preStop нет, но сам Valkey передаёт мастерство |

У `valkey-operator` результат расходится с первым прогоном (7–9 c). В логах реплики видно `Forced failover primary request accepted` с адреса старого мастера, а `CONFIG GET shutdown-on-sigterm` возвращает `failover`: сервер инициирует передачу мастерства при завершении процесса, отдельный preStop для этого не нужен. Почему в первом прогоне переключение заняло 7–9 c, по сохранившимся логам установить нельзя — нужен повтор с той же версией оператора и той же последовательностью удаления.

### Замер отказа зоны (2026-11-15)

Узел `rc1e-redis-atid` остановлен через `yc compute instance stop`; через 24 c он стал `NotReady`. Узел вернулся сам через 7,5 минуты (auto_repair), и поды вернулись на него в течение полуминуты: к 15:46:03 на узле стояли 7 подов из 8. API и две другие зоны работали всё время.

| Вариант | Поды по зонам | Мастер до отказа | Итог отказа `rc1e` |
|---|---|---|---|
| `redis-groundhog2k` | rc1a 2, rc1e 1 | rc1a | мастер не менялся, уцелели 2 сайдкара Sentinel из 3 |
| `redis-cloudpirates` | rc1d 2, rc1e 1 | rc1d | мастер не менялся, `ckquorum` 2 из 3 |
| `valkey-official` | данные и Sentinel по одному поду в каждой зоне | rc1d | мастер не менялся, `ckquorum` 3 из 3: отдельный под Sentinel-2 пересоздан в rc1a через несколько секунд |
| `redis-operator` | лидеры rc1e/rc1a/rc1d, реплики rc1e/rc1a/rc1e | шард 0 в rc1e, реплика тоже | `cluster_slots_fail: 5461`, шард 0 недоступен; после возврата узла лидер шарда 0 и реплика шарда 2 поднялись одиночными, кластер не восстановился |
| `valkey-operator` | 0-0 rc1e, 0-1 rc1d, 1-0 rc1a, 1-1 rc1d, 2-0 rc1d, 2-1 rc1e | мастера шардов 0 и 2 в rc1e | `cluster_state:fail` восемь минут: потеряны два мастера из трёх, выборы без кворума; собрался после возврата узла |

Три вывода из замера:

- **Под с PVC не переезжает из отказавшей зоны.** Диски создаются CSI в зоне пода и получают node affinity. Замены таких подов висят `Pending`, пока узел не вернётся: на других узлах нет ни их дисков, ни запаса памяти. Сообщение планировщика перечисляет причины по узлам: `0/3 nodes are available: 1 Insufficient memory, 1 node(s) didn't match PersistentVolume's node affinity, 1 node(s) had untolerated taint(s)`. Фильтры идут в порядке `NodeResourcesFit` → `VolumeBinding`, поэтому узлу без запаса памяти достаётся `Insufficient memory` (свободно было 235–321 Mi, а поду с `redis-server` 256Mi и Sentinel 64Mi нужно 320 Mi), а узлу, которому памяти хватило, — отказ по привязке диска. Отказавший узел закрыт taint `unreachable:NoSchedule`. Под без PVC (отдельный Sentinel у официального чарта Valkey) пересоздаётся в живой зоне через несколько секунд.
- **Мягкое разложение по зонам ничего не гарантирует.** `ScheduleAnyway` разрешает нарушить раскладку, когда на узле не хватает памяти, поэтому при пяти вариантах на трёх узлах у `redis-groundhog2k` и `redis-cloudpirates` одна зона осталась без подов. У `valkey-operator` в отказавшей зоне оказались два мастера из трёх: живые реплики были, но выборы не набрали кворум, и кластер лёг целиком. Режим `mode: Preferred` у spread в CR этому не мешает.
- **Кластерные операторы переживают отказ зоны по-разному.** `valkey-operator` собрался, как только под приехал обратно со своим PVC. `redis-operator` — нет: лидер шарда 0 и реплика шарда 2 поднялись одиночными узлами (`cluster_known_nodes: 1`), CR остаётся в `Bootstrap`, шард 0 остался `fail` с 5461 слотом, оператор пишет `Node ... is not empty` — та же проблема, что описана выше.

Отсюда практическое правило: отказ зоны проверяйте на одном-двух вариантах и с запасом памяти, иначе результат определяется тем, куда случайно сели поды, а не поведением Redis или Valkey.

### Актуальность версий

Фиксируйте в таблице: версию сервера из `INFO server`, версию чарта (`helm list`), дату релиза образа и дату последнего коммита оператора. Отдельно отметьте, как быстро вендор подтягивает CVE и новые мажорные версии.

## Ограничения стенда

- **`rc1b` не используется, `rc1c` выведена из эксплуатации.** `ru-central1-c` в `yc compute zone list` имеет статус `DOWN`, поэтому стенд собран из `ru-central1-a`, `ru-central1-d` и `ru-central1-e`. Региональный мастер требует подсетей во всех трёх зонах, поэтому здесь используется зональный.
- **Сетевую реализацию нельзя сменить после создания.** Cilium включается в Terraform блоком `network_implementation { cilium {} }` и требует у сервисного аккаунта кластера роль `k8s.tunnelClusters.agent`. Вместе с Calico он несовместим, а переключение на Calico или другой CNI возможно только пересозданием кластера.
- **Master не HA.** Падение зоны с мастером остановит API. Это осознанный компромисс по цене; отказоустойчивость данных проверяется на уровне подов и узлов.
- **У Redis нет официального Helm-чарта.** Redis в Helm представлен только community-чартами (в стенде — groundhog2k и CloudPirates), тогда как Valkey публикует официальный чарт. Это часть сравнения: у Valkey выше уровень поддержки в Kubernetes.
- **Разная цена Sentinel.** У groundhog2k и CloudPirates Sentinel — сайдкар в поде с данными (3 пода, 3 контейнера Sentinel), у официального чарта Valkey — три отдельных пода Sentinel (6 подов всего), у оператора Valkey и OT кластерный режим без Sentinel (6 подов). Сравнивайте не только задержку failover, но и накладные расходы.
- **PDB в чарте CloudPirates.** Чарт по умолчанию ставит `minAvailable: 1`, и если добавить к нему `maxUnavailable`, Kubernetes отвергает PDB (`minAvailable and maxUnavailable cannot be both set`). В values бюджет задаётся только через `maxUnavailable`, а `minAvailable` явно обнуляется ([CloudPirates-io/helm-charts#1922](https://github.com/CloudPirates-io/helm-charts/issues/1922)).
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

Yandex Cloud вместе с сетью создаёт неуправляемую группу безопасности по умолчанию (`default-sg-<network_id>`, флаг `default_for_network: true`) с открытым в обе стороны доступом. В state её нет, поэтому `terraform destroy` её не удалит, а сеть с висящей на ней группой не удалится. Перед `terraform destroy` удалите её вручную — в коде это отмечено TODO в `terraform/network.tf`:

```bash
yc vpc security-group delete --id "$(yc vpc security-group list --format json \
  | jq -r '.[] | select(.name | startswith("default-sg-")) | .id')"
```

## Источники

- Поддерживаемые версии Kubernetes в Yandex Cloud: <https://yandex.cloud/ru/docs/managed-kubernetes/concepts/k8s-supported-versions>
- Сетевые политики и Cilium в Managed Service for Kubernetes: <https://yandex.cloud/ru/docs/managed-kubernetes/concepts/network-policy>
- Настройка Cilium и Hubble UI: <https://yandex.cloud/ru/docs/managed-kubernetes/operations/cilium>
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
