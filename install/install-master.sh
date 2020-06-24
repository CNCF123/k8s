#!/bin/bash
#安装master节点

DockerVersion="19.03.9"
K8sVersion="v1.14.3"

#关闭SELinux
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/sysconfig/selinux
setenforce 0

#关闭防火墙
systemctl stop firewalld
systemctl disable firewalld

#关闭Swap分区
#Kubernetes v1.8+要求关闭系统 Swap：
sed -i /swap/s/^/#/g  /etc/fstab
swapoff -a && sysctl -w vm.swappiness=0

#配置内核参数,开启bridge-nf
cat >  /etc/sysctl.d/k8s.conf <<EOF 
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
EOF

sysctl --system

#加载ipvs相关模块
#kube-proxy使用ipvs模式，所以需要加ipvs相关的内核模块及安装ipset、ipvsadm软件包
cat > /etc/sysconfig/modules/ipvs.modules <<EOF
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4
EOF

chmod 755 /etc/sysconfig/modules/ipvs.modules && bash /etc/sysconfig/modules/ipvs.modules && lsmod | grep -e ip_vs -e nf_conntrack_ipv4

yum install -y ipset ipvsadm


#安装Docker
#安装依赖包
yum install -y yum-utils device-mapper-persistent-data lvm2
#添加yum仓库
yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
# 安装指定版本的Docker-CE:
# yum list docker-ce.x86_64 --showduplicates | sort -r
#安装docker
yum install -y docker-ce-${DockerVersion} docker-ce-cli-${DockerVersion} containerd.io

#创建docker配置文件
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF 
{
"insecure-registry": [
    "devops-hub.tutorabc.com.cn"
],
"registry-mirror": "https://5cs233bb.mirror.aliyuncs.com",
"graph": "/data/docker",
"exec-opts": ["native.cgroupdriver=systemd"]
}
EOF

#创建docker目录
mkdir -p /data/docker

#启动docker
systemctl daemon-reload
systemctl enable docker
systemctl start docker

docker --version


#安装kubeadm, kubelet和kubectl
#配置yum仓库
cat > /etc/yum.repos.d/kubernetes.repo <<EOF 
[kubernetes]
name=Kubernetes
baseurl=http://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=http://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg http://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

#查看可以安装的版本
### yum list kubelet kubeadm --showduplicates|sort -r

#安装指定的软件包 kubelet-1.14.3 kubeadm-1.14.3 kubectl-1.14.3
yum install -y kubelet-${K8sVersion} kubectl-${K8sVersion} kubeadm-${K8sVersion} --setopt=obsoletes=0
#设置开机自动启动kubelet
systemctl enable kubelet.service

#生成kubeadm-config.yaml文件
kubeadm config print init-defaults > /root/kubeadm-config.yaml

#kubeadm-config.yaml组成部署说明：
#InitConfiguration： 用于定义一些初始化配置，如初始化使用的token以及apiserver地址等
#ClusterConfiguration：用于定义apiserver、etcd、network、scheduler、controller-manager等master组件相关配置项
#KubeletConfiguration：用于定义kubelet组件相关的配置项
#KubeProxyConfiguration：用于定义kube-proxy组件相关的配置项

# 生成KubeletConfiguration示例文件 
#kubeadm config print init-defaults --component-configs KubeletConfiguration

# 生成KubeProxyConfiguration示例文件 
#kubeadm config print init-defaults --component-configs KubeProxyConfiguration

#创建kubeadm配置文件kubeadm-config.yaml

#初始化master节点
kubeadm init --config /root/kubeadm-config.yaml


#kubectl客户端配置
#mkdir -p $HOME/.kube
#cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
#chown $(id -u):$(id -g) $HOME/.kube/config
