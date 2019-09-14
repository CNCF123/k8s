# 升级Kubernetes集群


## 升级控制平面

只有master节点需要执行如下操作，需要逐节点操作。

### 升级kubeadm

    export VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
    export ARCH=amd64
    curl -sSL https://dl.k8s.io/release/${VERSION}/bin/linux/${ARCH}/kubeadm >/usr/bin/kubeadm
    chmod a+rx /usr/bin/kubeadm

### 查看升级计划

    kubeadm upgrade plan

### 升级控制节点

    kubeadm upgrade apply v1.14.2

## 升级主节点和从节点软件包

主节点和从节点软件包逐节点升级

### 驱逐节点上的pod并标记为不可调度

    kubectl drain k8s-m001 --ignore-daemonsets

### 升级软件包

    yum upgrade -y kubelet kubeadm --disableexcludes=kubernetes

### 更新kubelet配置文件

    kubeadm upgrade node config --kubelet-version $(kubelet --version | cut -d ' ' -f 2)

### 重启kubelet服务

    systemctl daemon-reload
    systemctl restart kubelet

### 查看kubelet状态

    systemctl status kubelet

### 标注节点为可调度

    kubectl uncordon k8s-m001

### 确定各节点状态为Ready

    kubectl get nodes

## 从失败状态恢复

如果kubeadm upgrade执行失败，它将尝试执行回滚。因此，如果这种情况发生在第一个master身上，那么集群仍然完好无损的可能性很大。你可以再次运行kubeadm upgrade apply，因为它是幂等的，最终应确保实际状态是你声明的所需状态。你可以使用参数--force运行 kubeadm upgrade apply命令更改运行的集群为y.y.y --> x.x.x，它可用于从糟糕的状态中恢复过来。

如果kubeadm upgrade apply是在其中一个辅助master上失败，则仍然有一个正在工作的已经升级的集群，但辅助master的状态有些不确定。你将不得不找出哪里出了问题，并手动加入辅助master。如上所述，有时升级其中一个辅助master时，首先等待重新启动的静态pod 失败，但在一两分钟的暂停后简单地重复该操作时会成功。