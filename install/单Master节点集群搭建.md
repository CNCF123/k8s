# 单Master节点集群搭建

## 准备节点

本次搭建集群启动4个虚拟机，其中1个做主节点，配置2c2g，另外3个做从节点，配置1c1g，IP地址如下：

| 主机名      | IP地址        | 用途  |
|------------|--------------|-------|
| k8s-master | 172.16.21.10 | 主节点 |
| k8s-node1  | 172.16.21.11 | 从节点 |
| k8s-node2  | 172.16.21.12 | 从节点 |
| k8s-node3  | 172.16.21.13 | 从节点 |

首先安装CentOS 7.6.1810 64位操作系统，并设置好IP地址。

## 系统配置

### 设置主机名

    hostnamectl set-hostname k8s-master
    hostnamectl set-hostname k8s-node1
    hostnamectl set-hostname k8s-node2
    hostnamectl set-hostname k8s-node3

### 配置hosts

各节点修改hosts，添加如下行：

    172.16.21.10 k8s-master
    172.16.21.11 k8s-node1
    172.16.21.12 k8s-node2
    172.16.21.13 k8s-node3

### 关闭SELinux

    $ sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
    $ setenforce 0

### 关闭防火墙

    $ systemctl stop firewalld
    $ systemctl disable firewalld

### 关闭Swap分区

Kubernetes v1.8+要求关闭系统 Swap：

    $ vi /etc/fstab
    注释swap相关的行
    $ swapoff -a && sysctl -w vm.swappiness=0

### 配置内核参数

    $ cat <<EOF >  /etc/sysctl.d/k8s.conf
    net.bridge.bridge-nf-call-ip6tables = 1
    net.bridge.bridge-nf-call-iptables = 1
    net.ipv4.ip_forward = 1
    vm.swappiness = 0
    EOF
    $ sysctl --system

### 加载ipvs相关模块

kube-proxy使用ipvs模式，所以需要加ipvs相关的内核模块及安装ipset、ipvsadm软件包。

加载相关内核模块

    $ cat > /etc/sysconfig/modules/ipvs.modules << EOF
    #!/bin/bash
    modprobe -- ip_vs
    modprobe -- ip_vs_rr
    modprobe -- ip_vs_wrr
    modprobe -- ip_vs_sh
    modprobe -- nf_conntrack_ipv4
    EOF

    $ chmod 755 /etc/sysconfig/modules/ipvs.modules && bash /etc/sysconfig/modules/ipvs.modules && lsmod | grep -e ip_vs -e nf_conntrack_ipv4

安装相关软件包

    $ yum install -y ipset ipvsadm

## 安装Docker

所有节点安装 Docker，推荐安装 1.13.1, 17.03, 17.06, 17.09, 18.06, 18.09，但是18.09+是未经测试的，不推荐使用。

### 安装依赖包

    $ yum install -y yum-utils \
    device-mapper-persistent-data \
    lvm2

### 添加yum仓库

    $  yum-config-manager \
    --add-repo \
    https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

### 安装Docker

    $ yum install -y docker-ce docker-ce-cli containerd.io

### 配置Docker

    $ mkdir /etc/docker
    $ cat << EOF > /etc/docker/daemon.json
    {
    "insecure-registry": [
        "hub.chenkaidi.com",
        "reg.chenkaidi.com"
    ],
    "registry-mirror": "https://q00c7e05.mirror.aliyuncs.com",
    }
    EOF

> 注意：insecure-registry为私有仓库地址，请填写你自己的私有仓库。

### 启动Docker

    $ systemctl enable docker && systemctl start docker

## 安装kubeadm, kubelet和kubectl

所有节点安装kubeadm, kubelet和kubectl，kubelet版本要与待安装的Kubernetes版本相同，否则可能会出现一些难以预料的问题。

### 配置yum仓库

    $ cat <<EOF > /etc/yum.repos.d/kubernetes.repo
    [kubernetes]
    name=Kubernetes
    baseurl=http://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
    enabled=1
    gpgcheck=0
    repo_gpgcheck=0
    gpgkey=http://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg
           http://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
    EOF

### 安装软件包

    $ yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

### 设置开机自动启动kubelet

    $ systemctl enable kubelet.service

## 配置Master节点

### 创建kubeadm配置文件kubeadm-config.yaml

    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    mode: "ipvs"
    ---
    apiVersion: kubeadm.k8s.io/v1beta1
    kind: ClusterConfiguration
    kubernetesVersion: v1.14.1
    apiServer:
        certSANs:
        - "172.16.21.10"
        extraArgs:
            allow-privileged: "true"
            feature-gates: "VolumeSnapshotDataSource=true,CSINodeInfo=true,    CSIDriverRegistry=true"
    controlPlaneEndpoint: "172.16.21.10:6443"
    networking:
        # This CIDR is a Canal default. Substitute or remove for your CNI provider.
        podSubnet: "10.244.0.0/16"
    controllerManager:
        extraArgs:
            address: 0.0.0.0
    scheduler:
        extraArgs:
            address: 0.0.0.0
    imageRepository: gcr.azk8s.cn/google-containers

### 初始化主节点

    $ kubeadm init --config=kubeadm-config.yaml

### kubectl客户端配置

    $ mkdir -p $HOME/.kube
    $ cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    $ chown $(id -u):$(id -g) $HOME/.kube/config

### 安装网络组件

在此选择Canal网络组件，其他网络组建见：https://kubernetes.io/docs/setup/independent/create-cluster-kubeadm/

    $ kubectl apply -f https://docs.projectcalico.org/v3.3/getting-started/kubernetes/installation/hosted/canal/rbac.yaml
    $ kubectl apply -f https://docs.projectcalico.org/v3.3/getting-started/kubernetes/installation/hosted/canal/canal.yaml

## 配置从节点

将三个从节点加入集群：

    $ kubeadm join 172.16.21.10:6443 --token tq6h4u.an7lj8cbao0g9u6r --discovery-token-ca-cert-hash sha256:6bac5edc327da9d5233d09c5279c73351c3a98fb8e92e24b3767dfffc89a5fa0

> 注意：主节点初始化完成后会生成加入集群的命令，请使用生成的命令将三个从节点加入集群。

## 安装Helm组件

### 安装helm客户端

根据操作系统到helm官网下载相应的二进制包，下载地址：https://github.com/helm/helm/releases，以CentOS系统为例：

    $ wget https://storage.googleapis.com/kubernetes-helm/helm-v2.13.1-linux-amd64.tar.gz
    $ tar xzvf helm-v2.13.1-linux-amd64.tar.gz
    $ mv linux-amd64/helm /usr/local/bin
    $ chmod +x /usr/local/bin/helm

### 创建服务器端tiller使用的账号

    $ vi helm-service-account.yaml
    # Create a service account for Helm and grant the cluster admin role.
    # It is assumed that helm should be installed with this service account
    # (tiller).
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: tiller
      namespace: kube-system
    ---
    apiVersion: rbac.authorization.k8s.io/v1beta1
    kind: ClusterRoleBinding
    metadata:
      name: tiller
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: cluster-admin
    subjects:
    - kind: ServiceAccount
      name: tiller
      namespace: kube-system

    $ kubectl apply -f helm-service-account.yaml

### 初始化安装tiller

    $ helm init --tiller-image gcr.azk8s.cn/kubernetes-helm/tiller:v2.13.1 --skip-refresh --service-account tiller

## 部署Traefik Ingress控制器

### 安装git

    $ yum install git

### 从官方网站下载Charts

    $ git clone https://github.com/helm/charts.git
    $ cd charts/stable

### 编写配置文件

    $ vi ./traefik/traefik.yaml
    serviceType: NodePort
    replicas: 3
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
      requests:
        cpu: 500m
        memory: 512Mi
    dashboard:
      enabled: true
      domain: traefik.chenkaidi.com
    service:
      nodePorts:
        http: 30080
        https: 30443
    rbac:
      enabled: true
    metrics:
      prometheus:
        enabled: true

> 注意：我设置traefik控制面板使用traefik.chenkaidi.com域名，你可以根据自己的域名做响应修改

### 设置traefik hostNetwork模式

    $ vi traefik/templet/deploymnet.yaml
    # 在43行加入hostNetwork: true

> 注意：需要各从节点中的80端口未使用，否则traefik服务将无法启动

### 部署traefik

    $ helm install ./traefik --name traefik --namespace kube-system -f traefik/traefik.yaml

> 注意：需要在charts/stable目录下执行上面命令。

配置生效后，traefik会使用宿主机上启动80端口，我们可以通过traefik所在宿主机的80端口访问traefik服务。

### 访问traefik控制面板

我们必须使用域名来访问traefik，因为traefik是根据域名来将用户请求转发到不同的后端服务的。

为了能够访问到traefik控制面板，我们有两种方法。

- 一种是修改本地hosts

    vi /etc/hosts
    # 在最后添加如下行
    172.16.21.11 traefik.chenkaidi.com


> 注意：我们有三个从节点，同时启动了三个traefik服务，每个节点上会启动一个traefik服务，但是我们访问时只需要访问其中一个就可以了。我们也可以在traefik前面加一个负载均衡，让负载均衡将请求流量分发到三个traefik服务上去，自己可以尝试搭建nginx或HaProxy实现此功能。
