# kubectl技巧

### 节点和Pod 

##### 如何查找非 `running` 状态的 Pod 呢？

   ```sql
    kubectl get pods -A --field-selector=status.phase!=Running | grep -v Complete
   ```

   顺便一说，`--field-selector` 是个值得深入一点的参数。

##### 获取节点node名称、CPU、Memory：

   ```csharp
   kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu,Memory:.status.capacity.memory
   ```

##### 获取节点列表，其中包含运行在每个节点上的 Pod 数量：

```sql
 kubectl get po -o json -A | \
   jq '.items | group_by(.spec.nodeName) | map({"nodeName": .[0].spec.nodeName, "count": length}) | sort_by(.count)'
```

##### 有时候 DaemonSet 因为某种原因没能在某个节点上启动。手动搜索会有点麻烦：

```shell
kubectl get node | grep -v \"$(kubectl -n NS名称 get pod --all-namespaces -o wide | fgrep pod名称 | awk '{print $8}' | xargs -n 1 echo -n "\|" | sed 's/[[:space:]]*//g')\"
```

##### 使用 `kubectl top` 获取 Pod 列表并根据其消耗的 CPU 或 内存进行排序：

```perl
 # cpu排序
 $ kubectl top pods -A | sort --reverse --key 3 --numeric
 # memory排序
 $ kubectl top pods -A | sort --reverse --key 4 --numeric
```

##### 获取 Pod 列表，并根据重启次数进行排序：

```
kubectl get pods —sort-by=.status.containerStatuses[0].restartCount
```

当然也可以使用 PodStatus 以及 ContainerStatus 的其它字段进行排序。

##### 如何输出 Pod 的 `requests` 和 `limits`：

```powershell
kubectl get pods -A -o=custom-columns='NAME:spec.containers[*].name,MEMREQ:spec.containers[*].resources.requests.memory,MEMLIM:spec.containers[*].resources.limits.memory,CPUREQ:spec.containers[*].resources.requests.cpu,CPULIM:spec.containers[*].resources.limits.cpu'
 NAME                                  MEMREQ       MEMLIM        CPUREQ   CPULIM
 coredns                               70Mi         170Mi         100m     <none>
 coredns                               70Mi         170Mi         100m     <none>
 ...
```

##### 获取指定资源的描述清单：

   ```yaml
    kubectl explain hpa
    KIND:     HorizontalPodAutoscaler
    VERSION:  autoscaling/v1
    DESCRIPTION:
         configuration of a horizontal pod autoscaler.
    FIELDS:
       apiVersion    <string>
    ...
   ```

### 网络

##### 获取集群节点的内部 IP：

```shell
 $ kubectl get nodes -o json | jq -r '.items[].status.addresses[]? | select (.type == "InternalIP") | .address' | \
   paste -sd "\n" -
 9.134.14.252
```

##### 获取所有的 Service 对象以及其 `nodePort`：

```csharp
 $ kubectl get -A svc -o json | jq -r '.items[] | [.metadata.name,([.spec.ports[].nodePort | tostring ] | join("|"))]| @tsv'

 kubernetes  null
 ...
```

##### 在排除 CNI（例如 Flannel）故障的时候，经常会需要检查路由来识别故障 Pod。Pod 子网在这里非常有用：

```shell
 $ kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' | tr " " "\n"                                                            fix-doc-azure-container-registry-config  ✭
 10.120.0.0/24
 10.120.1.0/24
 10.120.2.0/24
```

### 日志

##### 使用可读的时间格式输出日志：

```yaml
 $ kubectl logs -f fluentbit-gke-qq9w9  -c fluentbit --timestamps
 2020-09-10T13:10:49.822321364Z Fluent Bit v1.3.11
 2020-09-10T13:10:49.822373900Z Copyright (C) Treasure Data
 2020-09-10T13:10:49.822379743Z
 2020-09-10T13:10:49.822383264Z [2020/09/10 13:10:49] [ info] Configuration:
```

##### 只输出尾部日志：

```yaml
 kubectl logs -f fluentbit-gke-qq9w9  -c fluentbit --tail=10
 [2020/09/10 13:10:49] [ info] ___________
 [2020/09/10 13:10:49] [ info]  filters:
 [2020/09/10 13:10:49] [ info]      parser.0
 ...
```

##### 输出一个 Pod 中所有容器的日志：

```
kubectl -n my-namespace logs -f my-pod —all-containers
```

##### 使用标签选择器输出多个 Pod 的日志：

```
kubectl -n my-namespace logs -f -l app=nginx
```

##### 获取“前一个”容器的日志（例如崩溃的情况）：

```
kubectl -n my-namespace logs my-pod —previous
```



### 证书

##### 查看证书有效期

```
for item in `find /etc/kubernetes/pki -maxdepth 2 -name "*.crt"`;do openssl x509 -in $item -text -noout| grep Not;echo ==============$item===========;done
```



### 其它

##### 把 Secret 复制到其它命名空间：

```fsharp
 kubectl get secrets -o json --namespace namespace-old | \
   jq '.items[].metadata.namespace = "namespace-new"' | \
   kubectl create-f  -
```
