## 基于Kubeadm部署KubernetesHA 高可用集群

> DNS：CoreDNS
>
> Kube-proxy： IPVS模式
>
> Network： Calico、flannel
>
> 注意：
>
> 默认kubeadm一键部署`etcd`非集群高可用，
>
> 本示例使用`外接etcd`实现高可用集群，Master APIserver使用Keeplived；

### 1. 环境说明

- 五台机器进行部署K8S 集群环境，一台内网Harbor。其中`etcd`为所有节点部署
- Kubernetes中所有数据都是存储在etcd中的，etcd必须高可用集群
- Master使用keepalived高可用，Master主要是分发用户操作指令等操作；
- Master官方给出是用keepalived进行集群，建议也可以使用自建LB/商业AWS的（ALB ELB ）
- Node节点为搭配Taaefik解析IP高可用，也使用Keepalived，Tarefik解析 VIP上

|            System             |   Roles   |   IP Address    |
| :---------------------------: | :-------: | :-------------: |
|     Master Keepalived VIP     |    VIP    |   172.16.1.49   |
|      Node Keepalived VIP      |    VIP    |   172.16.1.59   |
| CentOS Linux release 7.4.1708 | Master01  |   172.16.1.50   |
| CentOS Linux release 7.4.1708 | Master02  |   172.16.1.51   |
| CentOS Linux release 7.4.1708 |  Node01   |   172.16.1.52   |
| CentOS Linux release 7.4.1708 |  Node02   |   172.16.1.53   |
| CentOS Linux release 7.4.1708 |  Node01   |   172.16.1.54   |
| CentOS Linux release 7.4.1708 | VM Harbor | xxx.xxx.xxx.xxx |

#### 1.1 集群说明

|    Software     | Version |
| :-------------: | :-----: |
|   Kubernetes    | 1.18.5  |
|    Docker-CE    | 19.03.5 |
|      Etcd       |  3.4.3  |
| Calico(二选一)  |  3.1.4  |
| Flannel(二选一) |  0.13   |
|    Dashboard    |  v2.0   |
|  Ingress-nginx  |  1.7.9  |
| kube-prometheus | v0.5.0  |
| metrics-server  | v0.4.1  |

### 2. 开始部署Kubernetes集群

#### 2.1 安装前准备

截至2019年2月，Kubernetes目前文档版本：v1.13+ 官方版本迭代很快，我们选择目前文档版本搭建

**K8S所有节点配置主机名**

```
# 设置主机名
hostnamectl set-hostname K8S01-Master01
hostnamectl set-hostname K8S01-Master02
hostnamectl set-hostname K8S01-Node01
hostnamectl set-hostname K8S01-Node02
hostnamectl set-hostname K8S01-Node03

# 配置hosts
cat <<EOF > /etc/hosts
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
172.16.1.50 master01 K8S01-Master01
172.16.1.51 master02 K8S01-Master02
172.16.1.52 node01 K8S01-Node01
172.16.1.53 node02 K8S01-Node02
172.16.1.54 node03 K8S01-Node03
EOF

#配置免密钥登陆
ssh-keygen   #一直回车
ssh-copy-id   master01
ssh-copy-id   master02
ssh-copy-id   node01
ssh-copy-id   node02
```

#### 2.2 优化系统和集群准备

```
#关闭防火墙
systemctl stop firewalld
systemctl disable firewalld

###关闭Swap
swapoff -a 
sed -i 's/.*swap.*/#&/' /etc/fstab

###禁用Selinux
setenforce  0 
sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/sysconfig/selinux 
sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config 
sed -i "s/^SELINUX=permissive/SELINUX=disabled/g" /etc/sysconfig/selinux 
sed -i "s/^SELINUX=permissive/SELINUX=disabled/g" /etc/selinux/config  

###报错请参考下面报错处理
modprobe br_netfilter   
cat <<EOF >  /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness=0
EOF
sysctl -p /etc/sysctl.d/k8s.conf
ls /proc/sys/net/bridge

###K8S源
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

###内核优化
echo "* soft nofile 204800" >> /etc/security/limits.conf
echo "* hard nofile 204800" >> /etc/security/limits.conf
echo "* soft nproc 204800"  >> /etc/security/limits.conf
echo "* hard nproc 204800"  >> /etc/security/limits.conf
echo "* soft  memlock  unlimited"  >> /etc/security/limits.conf
echo "* hard memlock  unlimited"  >> /etc/security/limits.conf

###kube-proxy开启ipvs的前置条件
# 原文：https://github.com/kubernetes/kubernetes/blob/master/pkg/proxy/ipvs/README.md
# 参考：https://www.qikqiak.com/post/how-to-use-ipvs-in-kubernetes/

# 加载模块 <module_name>
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4

# 检查加载的模块
lsmod | grep -e ipvs -e nf_conntrack_ipv4
# 或者
cut -f1 -d " "  /proc/modules | grep -e ip_vs -e nf_conntrack_ipv4

#所有node节点安装ipvsadm
yum install ipvsadm -y
ipvsadm -l -n
# Version INFO: IP Virtual Server version 1.2.1 (size=4096)
```

#### 2.3 安装Docker-CE

```
yum install -y yum-utils device-mapper-persistent-data lvm2
yum-config-manager 
    --add-repo 
    https://download.docker.com/linux/centos/docker-ce.repo

yum makecache fast
yum install -y --setopt=obsoletes=0 
  docker-ce-18.06.1.ce-3.el7

systemctl start docker
systemctl enable docker
```

#### 2.4 所有节点配置Docker镜像加速

阿里云容器镜像加速器配置地址https://dev.aliyun.com/search.html 登录管理中心获取个人专属加速器地址

```
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": ["https://3csy84rx.mirror.aliyuncs.com"]
}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### 3. 生成TLS证书和秘钥

#### 3.1 Kubernetes 集群所需证书

> `ca`证书为集群admin证书。
>
> `etcd`证书为etcd集群使用。
>
> `shinezone`证书为Harbor使用。

|      CA&Key       | etcd | api-server | proxy | kebectl | Calico | harbor |
| :---------------: | :--: | :--------: | :---: | :-----: | :----: | :----: |
|      ca.csr       |  √   |     √      |   √   |    √    |   √    |        |
|      ca.pem       |  √   |     √      |   √   |    √    |   √    |        |
|    ca-key.pem     |  √   |     √      |   √   |    √    |   √    |        |
|      ca.pem       |  √   |            |       |         |        |        |
|     etcd.csr      |  √   |            |       |         |        |        |
|   etcd-key.pem    |  √   |            |       |         |        |        |
| shinezone.com.crt |      |            |       |         |        |   √    |
| shinezone.com.key |      |            |       |         |        |   √    |

#### 3.2 安装CFSSL

- K8S01执行

```
yum install wget -y
wget https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
wget https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
wget https://pkg.cfssl.org/R1.2/cfssl-certinfo_linux-amd64
chmod +x cfssl_linux-amd64
mv cfssl_linux-amd64 /usr/local/bin/cfssl
chmod +x cfssljson_linux-amd64
mv cfssljson_linux-amd64 /usr/local/bin/cfssljson
chmod +x cfssl-certinfo_linux-amd64
mv cfssl-certinfo_linux-amd64 /usr/local/bin/cfssl-certinfo
export PATH=/usr/local/bin:$PATH
```

#### 3.3 创建CA文件,生成etcd证书

```
mkdir /root/ssl
cd /root/ssl
cat >  ca-config.json <<EOF
{
"signing": {
"default": {
  "expiry": "8760h"
},
"profiles": {
  "kubernetes-Soulmate": {
    "usages": [
        "signing",
        "key encipherment",
        "server auth",
        "client auth"
    ],
    "expiry": "8760h"
  }
}
}
}
EOF

cat >  ca-csr.json <<EOF
{
"CN": "kubernetes-Soulmate",
"key": {
"algo": "rsa",
"size": 2048
},
"names": [
{
  "C": "CN",
  "ST": "shanghai",
  "L": "shanghai",
  "O": "k8s",
  "OU": "System"
}
]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

#hosts项需要加入所有etcd集群节点，建议将所有node也加入，便于扩容etcd集群。
cat > etcd-csr.json <<EOF
{
  "CN": "etcd",
  "hosts": [
    "127.0.0.1",
    "172.16.1.50",
    "172.16.1.51",
    "172.16.1.52",
    "172.16.1.53",
    "172.16.1.54"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "shanghai",
      "L": "shanghai",
      "O": "k8s",
      "OU": "System"
    }
  ]
}
EOF

cfssl gencert -ca=ca.pem 
  -ca-key=ca-key.pem 
  -config=ca-config.json 
  -profile=kubernetes-Soulmate etcd-csr.json | cfssljson -bare etcd
```

字段说明

- 如果 hosts 字段不为空则需要指定授权使用该证书的?**IP 或域名列表**
- `ca-config.json`：可以定义多个 profiles，分别指定不同的过期时间、使用场景等参数；后续在签名证书时使用某个 profile；
- `signing`：表示该证书可用于签名其它证书；生成的 ca.pem 证书中?`CA=TRUE`；
- `server auth`：表示client可以用该 CA 对server提供的证书进行验证；
- `client auth`：表示server可以用该CA对client提供的证书进行验证；
- “CN”：`Common Name`，kube-apiserver 从证书中提取该字段作为请求的用户名 (User Name)；浏览器使用该字段验证网站是否合法；
- “O”：`Organization`，kube-apiserver 从证书中提取该字段作为请求用户所属的组 (Group)；

#### 3.4 分发证书到所有节点

- Master01执行

> 本集群所有所有节点安装etcd，因此需要证书分发所有节点。

```
mkdir -p /etc/etcd/ssl
cp etcd.pem etcd-key.pem ca.pem /etc/etcd/ssl/
scp -r /etc/etcd/ master02:/etc/
scp -r /etc/etcd/ node01:/etc/
scp -r /etc/etcd/ node02:/etc/
scp -r /etc/etcd/ node03:/etc/
```

### 4. 安装配置etcd

#### 4.1 安装etcd

- 所有节点执行

```
yum install etcd -y   
mkdir -p /var/lib/etcd
```

#### 4.2 配置etcd

master01的`etcd.service`

```
cat <<EOF >/usr/lib/systemd/system/etcd.service
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
ExecStart=/usr/bin/etcd 
  --name k8s01 
  --cert-file=/etc/etcd/ssl/etcd.pem 
  --key-file=/etc/etcd/ssl/etcd-key.pem 
  --peer-cert-file=/etc/etcd/ssl/etcd.pem 
  --peer-key-file=/etc/etcd/ssl/etcd-key.pem 
  --trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --peer-trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --initial-advertise-peer-urls https://172.16.1.50:2380 
  --listen-peer-urls https://172.16.1.50:2380 
  --listen-client-urls https://172.16.1.50:2379,http://127.0.0.1:2379 
  --advertise-client-urls https://172.16.1.50:2379 
  --initial-cluster-token etcd-cluster-0 
  --initial-cluster k8s01=https://172.16.1.50:2380,k8s02=https://172.16.1.51:2380,k8s03=https://172.16.1.52:2380,k8s04=https://172.16.1.53:2380,k8s05=https://172.16.1.54:2380 
  --initial-cluster-state new 
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

master02的`etcd.service`

```
cat <<EOF >/usr/lib/systemd/system/etcd.service
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
ExecStart=/usr/bin/etcd 
  --name k8s02 
  --cert-file=/etc/etcd/ssl/etcd.pem 
  --key-file=/etc/etcd/ssl/etcd-key.pem 
  --peer-cert-file=/etc/etcd/ssl/etcd.pem 
  --peer-key-file=/etc/etcd/ssl/etcd-key.pem 
  --trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --peer-trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --initial-advertise-peer-urls https://172.16.1.51:2380 
  --listen-peer-urls https://172.16.1.51:2380 
  --listen-client-urls https://172.16.1.51:2379,http://127.0.0.1:2379 
  --advertise-client-urls https://172.16.1.51:2379 
  --initial-cluster-token etcd-cluster-0 
  --initial-cluster k8s01=https://172.16.1.50:2380,k8s02=https://172.16.1.51:2380,k8s03=https://172.16.1.52:2380,k8s04=https://172.16.1.53:2380,k8s05=https://172.16.1.54:2380 
  --initial-cluster-state new 
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

node01的`etcd.service`

```
cat <<EOF >/usr/lib/systemd/system/etcd.service
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
ExecStart=/usr/bin/etcd 
  --name k8s03 
  --cert-file=/etc/etcd/ssl/etcd.pem 
  --key-file=/etc/etcd/ssl/etcd-key.pem 
  --peer-cert-file=/etc/etcd/ssl/etcd.pem 
  --peer-key-file=/etc/etcd/ssl/etcd-key.pem 
  --trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --peer-trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --initial-advertise-peer-urls https://172.16.1.52:2380 
  --listen-peer-urls https://172.16.1.52:2380 
  --listen-client-urls https://172.16.1.52:2379,http://127.0.0.1:2379 
  --advertise-client-urls https://172.16.1.52:2379 
  --initial-cluster-token etcd-cluster-0 
  --initial-cluster k8s01=https://172.16.1.50:2380,k8s02=https://172.16.1.51:2380,k8s03=https://172.16.1.52:2380,k8s04=https://172.16.1.53:2380,k8s05=https://172.16.1.54:2380 
  --initial-cluster-state new 
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

node02的`etcd.service`

```
cat <<EOF >/usr/lib/systemd/system/etcd.service
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
ExecStart=/usr/bin/etcd 
  --name k8s04 
  --cert-file=/etc/etcd/ssl/etcd.pem 
  --key-file=/etc/etcd/ssl/etcd-key.pem 
  --peer-cert-file=/etc/etcd/ssl/etcd.pem 
  --peer-key-file=/etc/etcd/ssl/etcd-key.pem 
  --trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --peer-trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --initial-advertise-peer-urls https://172.16.1.53:2380 
  --listen-peer-urls https://172.16.1.53:2380 
  --listen-client-urls https://172.16.1.53:2379,http://127.0.0.1:2379 
  --advertise-client-urls https://172.16.1.53:2379 
  --initial-cluster-token etcd-cluster-0 
  --initial-cluster k8s01=https://172.16.1.50:2380,k8s02=https://172.16.1.51:2380,k8s03=https://172.16.1.52:2380,k8s04=https://172.16.1.53:2380,k8s05=https://172.16.1.54:2380 
  --initial-cluster-state new 
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

node03的`etcd.service`

```
cat <<EOF >/usr/lib/systemd/system/etcd.service
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target
Documentation=https://github.com/coreos

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
ExecStart=/usr/bin/etcd 
  --name k8s05 
  --cert-file=/etc/etcd/ssl/etcd.pem 
  --key-file=/etc/etcd/ssl/etcd-key.pem 
  --peer-cert-file=/etc/etcd/ssl/etcd.pem 
  --peer-key-file=/etc/etcd/ssl/etcd-key.pem 
  --trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --peer-trusted-ca-file=/etc/etcd/ssl/ca.pem 
  --initial-advertise-peer-urls https://172.16.1.54:2380 
  --listen-peer-urls https://172.16.1.54:2380 
  --listen-client-urls https://172.16.1.54:2379,http://127.0.0.1:2379 
  --advertise-client-urls https://172.16.1.54:2379 
  --initial-cluster-token etcd-cluster-0 
  --initial-cluster k8s01=https://172.16.1.50:2380,k8s02=https://172.16.1.51:2380,k8s03=https://172.16.1.52:2380,k8s04=https://172.16.1.53:2380,k8s05=https://172.16.1.54:2380 
  --initial-cluster-state new 
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

#### 4.3 启动etcd

```
 systemctl daemon-reload
 systemctl enable etcd
 systemctl start etcd
 systemctl status etcd
```

#### 4.4 集群状态检查(维护)

> 使用v3版本API

```
echo "export ETCDCTL_API=3" >>/etc/profile  && source /etc/profile
etcdctl version
etcdctl version: 3.2.18
API version: 3.2
```

> 查看集群健康状态

```
Fetcdctl --endpoints=https://172.16.1.50:2379,https://172.16.1.51:2379,https://172.16.1.52:2379,https://172.16.1.53:2379,https://172.16.1.54:2379 --cacert=/etc/etcd/ssl/ca.pem   --cert=/etc/etcd/ssl/etcd.pem   --key=/etc/etcd/ssl/etcd-key.pem   endpoint health
//输出信息如下：
https://172.16.1.54:2379 is healthy: successfully committed proposal: took = 1.911784ms
https://172.16.1.50:2379 is healthy: successfully committed proposal: took = 2.648385ms
https://172.16.1.52:2379 is healthy: successfully committed proposal: took = 3.472479ms
https://172.16.1.51:2379 is healthy: successfully committed proposal: took = 2.850887ms
https://172.16.1.53:2379 is healthy: successfully committed proposal: took = 3.711259ms
```

> 查询所有key

```
etcdctl --endpoints=https://172.16.1.50:2379,https://172.16.1.51:2379,https://172.16.1.52:2379,https://172.16.1.53:2379,https://172.16.1.54:2379 --cacert=/etc/etcd/ssl/ca.pem   --cert=/etc/etcd/ssl/etcd.pem   --key=/etc/etcd/ssl/etcd-key.pem    get / --prefix --keys-only

// kubeadm初始化之前是没有任何信息的，初始化完成后查询得到的信息如：
/registry/apiregistration.k8s.io/apiservices/v1.
/registry/apiregistration.k8s.io/apiservices/v1.apps
/registry/apiregistration.k8s.io/apiservices/v1.authentication.k8s.io
/registry/apiregistration.k8s.io/apiservices/v1.authorization.k8s.io
/registry/apiregistration.k8s.io/apiservices/v1.autoscaling
/registry/apiregistration.k8s.io/apiservices/v1.batch
........................
```

> 清除`所有/指定`key(**生成环境慎用**)
>
> 线上环境如有k8s组件出现问题,需要针对特定问题key进行清除操作。

```
 etcdctl --endpoints=https://172.16.1.50:2379,https://172.16.1.51:2379,https://172.16.1.52:2379,https://172.16.1.53:2379,https://172.16.1.54:2379 --cacert=/etc/etcd/ssl/ca.pem   --cert=/etc/etcd/ssl/etcd.pem   --key=/etc/etcd/ssl/etcd-key.pem    del /registry/apiregistration.k8s.io/apiservices/v1.batch --prefix 
```

### 5.安装配置Kubeadm

> 集群所有节点安装`kebelet` `kubeadm` `kebectl`

```
yum install -y kubelet kubeadm kubectl
###暂不启动，未初始化前启动也会报错
systemctl enable kubelet   
```

#### 5.1 配置kubelet

> 所有节点修改，kubelet类似Agent，每台Node上必须要安装的组件

```
// 所有机器执行
sed -i s#systemd#cgroupfs#g /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
echo 'Environment="KUBELET_EXTRA_ARGS=--v=2 --fail-swap-on=false --pod-infra-container-image=harbor.domain.com/shinezonetest/pause-amd64:3.1"' >>  /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
```

#### 5.2 加载配置文件

```
systemctl daemon-reload
systemctl enable kubelet
```

### 6.Master节点高可用

> Master节点高可用使用keepalived，也可以使用商业ELB ALB SLB，或自建N’gin’x负载均衡。

#### 6.1 安装keepalived

- master节点执行

```
yum install -y keepalived
systemctl enable keepalived
```

#### 6.2 配置Keepalived

> 注意修改`interface`网卡名，`priority`权重值，`unicast_peer`

Master01 配置文件

```
cat <<EOF >/etc/keepalived/keepalived.conf
global_defs {
   router_id LVS_k8s
}

vrrp_script CheckK8sMaster {
    script "curl -k https://172.16.1.49:6443"    #VIP Address
    interval 3
    timeout 9
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface ens32       #Your Network Interface Name
    virtual_router_id 61
    priority 120          #权重，数字大的为主，数字一样则选择第一台为Master
    advert_int 1
    mcast_src_ip 172.16.1.50  #local IP
    nopreempt
    authentication {
        auth_type PASS
        auth_pass sqP05dQgMSlzrxHj
    }
    unicast_peer {
        #172.16.1.50
        172.16.1.51    #另外一台masterIP
    }
    virtual_ipaddress {
        172.16.1.49/24    # VIP
    }
    track_script {
        CheckK8sMaster
    }

}
EOF
```

Master02配置文件

```
cat <<EOF >/etc/keepalived/keepalived.conf
global_defs {
   router_id LVS_k8s
}

vrrp_script CheckK8sMaster {
    script "curl -k https://172.16.1.49:6443"
    interval 3
    timeout 9
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface ens32
    virtual_router_id 61
    priority 110
    advert_int 1
    mcast_src_ip 172.16.1.51
    nopreempt
    authentication {
        auth_type PASS
        auth_pass sqP05dQgMSlzrxHj
    }
    unicast_peer {
        172.16.1.50
        #172.16.1.51
    }
    virtual_ipaddress {
        172.16.1.49/24
    }
    track_script {
        CheckK8sMaster
    }

}
EOF
```

#### 6.3 启动Keepalived

```
sed s#'KEEPALIVED_OPTIONS="-D"'#'KEEPALIVED_OPTIONS="-D -d -S 0"'#g /etc/sysconfig/keepalived -i   //配置日志文件
echo "local0.*    /var/log/keepalived.log" >> /etc/rsyslog.conf
service rsyslog restart
systemctl start keepalived
systemctl status keepalived
```

#### 6.4 测试Keepalived可用性

> 测试：关闭一台Master机器，看IP是否漂移，API是否可用。

```
//确认VIP在Master01上
ip a | grep inet |grep "172.16"
    inet 172.16.1.50/21 brd 172.16.7.255 scope global ens32
    inet 172.16.1.49/24 scope global ens32   //VIP
    
// 关闭Master01机器，确认VIP是否飘逸
ip a |grep inet |grep "172.16"
    inet 172.16.1.51/21 brd 172.16.7.255 scope global ens32
    inet 172.16.1.49/24 scope global ens32  //可以看到瞬间就偏移到了Master02机器上
    
// 确认APi服务可用性,也可在下步初始化集群后测试，直接访问dashboard看效果。
curl https://your_dashboard_address/ -I
HTTP/1.1 200 OK
Server: nginx/1.10.0
Date: Wed, 06 Jun 2018 05:58:22 GMT
Content-Type: text/html; charset=utf-8
Content-Length: 990
Connection: keep-alive
Accept-Ranges: bytes
Cache-Control: no-store
Last-Modified: Tue, 13 Feb 2018 11:17:03 GMT
```

### 7.初始化集群

> Master机器添加初始化配置文件, V1.13版本后version版本使用v1beta1 语法变化很大

```
#cat EOF方式格式会乱掉，直接vim 复制粘贴进去，保持格式不变
#vim config.yaml   :set paste  

apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"  #使用IPVS模式，非iptables
---
apiVersion: kubeadm.k8s.io/v1beta1  #v1beta1版本,非v1alpha版本，语法会有变化
certificatesDir: /etc/kubernetes/pki   
clusterName: kubernetes
controlPlaneEndpoint: 172.16.1.49:6443  #Keeplived 虚拟IP地址
controllerManager: {}
dns:
  type: CoreDNS  #默认DNS：CoreDNS
imageRepository: k8s.gcr.io   #官方镜像
#imageRepository: harbor.domain.com/k8s   #可修改为自己的Har镜像库
kind: ClusterConfiguration
kubernetesVersion: v1.13.3   #K8S版本
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12  #SVC网络段 
  podSubnet: 100.64.0.0/10     #POD网络段
apiServer:
        certSANs:  
        - 172.16.1.50
        - 172.16.1.51
        - 172.16.1.52
        - 172.16.1.53
        - 172.16.1.54
        extraArgs: 
           etcd-cafile: /etc/etcd/ssl/ca.pem
           etcd-certfile: /etc/etcd/ssl/etcd.pem
           etcd-keyfile: /etc/etcd/ssl/etcd-key.pem
etcd:  #使用外接etcd高可用
    external:
        caFile: /etc/etcd/ssl/ca.pem
        certFile: /etc/etcd/ssl/etcd.pem
        keyFile: /etc/etcd/ssl/etcd-key.pem
        endpoints:
        - https://172.16.1.50:2379
        - https://172.16.1.51:2379
        - https://172.16.1.52:2379
        - https://172.16.1.53:2379
        - https://172.16.1.54:2379
```

#### 7.1 初始化集群

- Master01操作

```
kubeadm init --config config.yaml  

# 初始化过程中可以journalctl -u kubelet -f查看log，可能会报错cni网络问题，因为我们指定了网络，calico还没安装，所以报错，等calico安装完成就好了
```

初始化成功后输出信息：

```
Your Kubernetes master has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

You can now join any number of machines by running the following on each node
as root:

  kubeadm join 172.16.1.49:6443 --token b99a00.a144ef80536d4344 --discovery-token-ca-cert-hash sha256:8c
```

初始化完成后执行相关命令

```
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

查看状态

```
kubectl get cs
NAME                 STATUS    MESSAGE             ERROR
controller-manager   Healthy   ok                  
scheduler            Healthy   ok                  
etcd-0               Healthy   {"health":"true"}   
etcd-2               Healthy   {"health":"true"}   
etcd-3               Healthy   {"health":"true"}   
etcd-4               Healthy   {"health":"true"}   
etcd-1               Healthy   {"health":"true"}
```

> 注意，多台Master的主机都要进行初始化，第二台master初始化也需要config.yaml文件，前提需要将

- Master02操作

```
#分发kebeadm生成的证书文件和密码文件
#每台Master机器的证书和密码文件都是相同的，有新的Master加入，直接分发初始化即可。

scp -r /etc/kubernetes/pki  master02:/etc/kubernetes/
//然后初始化，执行命令
kubeadm init --config config.yaml 
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

#### 7.2 初始化失败解决办法

```
kubeadm reset
// 或者删除相关文件和images
rm -rf /etc/kubernetes/*.conf
rm -rf /etc/kubernetes/manifests/*.yaml
docker ps -a |awk '{print $1}' |xargs docker rm -f
systemctl  stop kubelet
```

再次初始化前需要执行清除etcd所有数据的操作。

```
etcdctl --endpoints=https://172.16.1.50:2379,https://172.16.1.51:2379,https://172.16.1.52:2379,https://172.16.1.53:2379,https://172.16.1.54:2379 --cacert=/etc/etcd/ssl/ca.pem   --cert=/etc/etcd/ssl/etcd.pem   --key=/etc/etcd/ssl/etcd-key.pem    del / --prefix
```

### 8. 部署网络组件

> Flanneld和Calico都是解决容器通信组件，任选一个即可，这里使用DaemonSet部署，只在Master01执行

#### 8.1 Calico组件部署（二选一）

```
wget https://docs.projectcalico.org/v3.1/getting-started/kubernetes/installation/hosted/rbac-kdd.yaml
wget  https://docs.projectcalico.org/v3.1/getting-started/kubernetes/installation/hosted/kubernetes-datastore/calico-networking/1.7/calico.yaml
#修改calico.yaml里image镜像路径部分,已推内网harbor,有梯子的可以默认直接apply yaml文件
grep image calico.yaml 

        - image: harbor.domain.com/shinezonetest/calico-typha:1.0
          image: harbor.domain.com/shinezonetest/calico-node:1.0
          image: harbor.domain.com/shinezonetest/calico-cni:1.0
          
kubectl apply -f rbac-kdd.yaml
kubectl apply -f calico.yaml
```

#### 8.2 Flannel组件部署(二选一)

- 目前都是使用Calico网络，二选一即可，Flannel不需要部署

```
mkdir -p /run/flannel/
cat >/run/flannel/subnet.env <<EOF
FLANNEL_NETWORK=10.244.0.0/16
FLANNEL_SUBNET=10.244.0.1/24
FLANNEL_MTU=1450
FLANNEL_IPMASQ=true
EOF
wget https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
  #版本信息：quay.io/coreos/flannel:v0.13.0-amd64
kubectl create -f  kube-flannel.yml
```

#### 8.3 查看集群状态

> 集群中组件通信都要基于Calico/Flanneld，需要等到网络组件启动后才可以确认。

```
$ kubectl get nodes
NAME             STATUS   ROLES    AGE     VERSION
k8s01-master01   Ready    master   22h     v1.13.3
k8s01-master02   Ready    master   6h47m   v1.13.3
k8s01-node01     Ready    <none>   22h     v1.13.3
k8s01-node02     Ready    <none>   22h     v1.13.3
k8s01-node03     Ready    <none>   22h     v1.13.3

$ kubectl get pods -n kube-system
NAME                                     READY   STATUS    RESTARTS   AGE
calico-node-bt2gq                        2/2     Running   0          22h
calico-node-gln4j                        2/2     Running   0          22h
calico-node-s4xj7                        2/2     Running   0          6h47m
calico-node-ttj6q                        2/2     Running   0          22h
calico-node-wsc7s                        2/2     Running   0          22h
coredns-86c58d9df4-n8tvw                 1/1     Running   0          22h
coredns-86c58d9df4-qlq2n                 1/1     Running   0          22h
kube-apiserver-k8s01-master01            1/1     Running   0          22h
kube-apiserver-k8s01-master02            1/1     Running   0          6h47m
kube-controller-manager-k8s01-master01   1/1     Running   0          22h
kube-controller-manager-k8s01-master02   1/1     Running   0          6h47m
kube-proxy-89f5j                         1/1     Running   0          6h47m
kube-proxy-fnc9t                         1/1     Running   0          22h
kube-proxy-gf4xt                         1/1     Running   0          22h
kube-proxy-j7ltr                         1/1     Running   0          22h
kube-proxy-z4tbz                         1/1     Running   0          22h
kube-scheduler-k8s01-master01            1/1     Running   0          22h
kube-scheduler-k8s01-master02            1/1     Running   0          6h47m
```

#### 8.4 测试Calico DNS网络问题

> DNS使用CoreDNS，是集群初始化默认启用的，Node之间通信是依赖Calico的

**坑一，Busybox镜像Bug**

```
$ kubectl run curl --image=radial/busyboxplus:curl   #启动busybox
$ nslookup kubernetes  #非全路径则无法解析
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local  
nslookup: can‘t resolve kubernetes

$ nslookup kubernetes.default.svc.cluster.local     #nslookup解析全路径就可以解析
Server:    10.96.0.10 
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      kubernetes.default.svc.cluster.local
Address 1: 10.96.0.1 kubernetes.default.svc.cluster.local

# 使用DNSTOOLS工具
$ kubectl run -it --rm --image=infoblox/dnstools dns-client
dnstools# ping kubernetes   #确认可以解析内部
PING kubernetes (10.96.0.1): 56 data bytes
64 bytes from 10.96.0.1: seq=0 ttl=64 time=0.042 ms

dnstools# ping www.qq.com   #确认pod可以访问外网
```

**坑二，pod请求外网，DNS报错io/timeout**

> 简单记录下这里的排查思路。
>
> 当我整个集群都部署完成，监控就位的时候，发现Alertmanager无法发送邮件，然后确认Alert信息从Prometheus递交给了Alertmanager。
>
> 查看POD日志，POD日志显示无法链接到SMTP服务器，这时候意识到可能DNS解析有问题，然后就启动了busybox测试DNS，What Fuck! 我CoreDNS 解析集群内部的SVC都解析不到，那我Tarefik怎么转发工作的。
>
> 最后排查半天原来是busybox镜像有bug，nslookup 全路径就可以解析，如以上**坑一** ，使用dnstools即可解决，内网通了很开心，然后外网还是不通，其余POD没有报错日志，唯有DNS一直报错 timeout。
>
> 到了这个时候一直认为是CoreDNS问题，先去了解了下K8S集群中DNS工作原理，参考链接：https://www.simpleapples.com/2018/07/15/solving-kubernetes-dns-problem/
>
> DNS解析外部地址需要借助上层DNS，CoreDNS里面也有配置依赖Node DNS，默认/etc/resolv.conf 里面的nameserver，接着使用`kuberctl exec <dns_pod_name> cat /etc/resolv.conf -n kube-system `查看我DNS确实依赖了我Node的DNS呀 参考文档：https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/，什么情况，为什么还不能解析外网。
>
> 然后将CoreDNS换成了Kube-DNS，还是不行，各种尝试，reset集群，重启机器，耗时了将近一天时间，集群也重新建立了多次，最后开始怀疑自己排查点好像出错了。
>
> 开始意识到应该不是DNS问题，可能是我的Calico网络有问题，但是我POD之间又是可以通信，很奇怪，终于皇天不负有心人，我开始将重心搜素放到了`pod无法上外网`让我找到了以下https://blog.csdn.net/kozazyh/article/details/80595782，这里我一直认为我kube-proxy使用的IPVS模块，不会和Iptable有关系，直到我加了2条POD和SVC的iptable NAT规则，发现网络居然通了。。。。 我擦，这可能不是官方的正确解法，可能是我Calico网络没配置好，或者我IPVS这块理解有问题，还是要多看官方文档。

```
#解决办法：

cat config.yaml   #你的SVC和POD地址段，添加2条规则
$ ps uax |grep kube-proxy  //确保加载了--cluster-cidr
$ iptables -nvL |grep FORWARD  //查看FORWARD 是否为ACCEPT 
$ iptables -P FORWARD ACCEPT  //开启IPtableS转发ACCEPT
$ sysctl -a | grep ip_forward //确认系统ip_forward开启

$ /sbin/iptables -t nat -I POSTROUTING -s  100.64.0.0/10 -j MASQUERADE
$ /sbin/iptables -t nat -I POSTROUTING -s  10.96.0.0/12 -j MASQUERADE

$ kubectl run -it --rm --image=infoblox/dnstools dns-client #测试
dnstools# ping qq.com  #可以ping通
```

### 9. 部署Dashboard

#### 9.1 部署

```
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.0.4/aio/deploy/recommended.yaml
```

#### 9.2登陆访问

```
kubectl get svc -A |grep dashboard
kubernetes-dashboard   dashboard-metrics-scraper   ClusterIP   10.100.123.216   <none>        8000/TCP                 5d
kubernetes-dashboard   kubernetes-dashboard        NodePort    10.101.0.107     <none>        443:31468/TCP            5d
```

获取token,通过令牌登陆

```
kubectl -n kubernetes-dashboard describe secret $(kubectl -n kubernetes-dashboard get secret | grep admin-user | awk '{print $1}')
```

通过浏览器

```
https://ip:31468
```

### 10 部署Ingress-nginx

#### 10.1 使用DaemonSet方式进行部署

```
https://github.com/CNCF123/Ingress-controller/blob/master/ingress-nginx/ingress-controller-v0.30.yaml
```

```
kubectl apply -f https://raw.githubusercontent.com/CNCF123/Ingress-controller/master/ingress-nginx/ingress-controller-v0.30.yaml
```