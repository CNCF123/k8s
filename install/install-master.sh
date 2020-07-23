#!/bin/bash
#安装master节点

#无论是否已安装，先卸载 kubelet kubeadm kubectl
yum remove -y kubelet kubeadm kubectl

#设置k8s的版本
K8sVersion="1.18.3"
vK8sVersion="v1.18.3"

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
yum install -y docker-ce-19.03.5 docker-ce-cli-19.03.5 containerd.io

#创建docker配置文件
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF 
{
"insecure-registry": [
    "devops-hub.tutorabc.com.cn"
],
"registry-mirrors": ["https://5cs233bb.mirror.aliyuncs.com"],
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

#安装指定的软件包
yum install -y kubelet-${K8sVersion} kubectl-${K8sVersion} kubeadm-${K8sVersion} --setopt=obsoletes=0
#设置开机自动启动kubelet
systemctl enable kubelet.service

#查询k8s安装镜像的版本
kubeadm config images list > /root/kubeadm-config-images-list

#获取 pause,etcd,coredns的版本
PauseVersion=`grep 'pause' /root/kubeadm-config-images-list |awk -F: '{print $2}'`
EtcdVersion=`grep 'etcd' /root/kubeadm-config-images-list |awk -F: '{print $2}'`
CorednsVersion=`grep 'coredns' /root/kubeadm-config-images-list |awk -F: '{print $2}'`

images=(
    kube-apiserver:${vK8sVersion}
    kube-controller-manager:${vK8sVersion}
    kube-scheduler:${vK8sVersion}
    kube-proxy:${vK8sVersion}
    pause:${PauseVersion}
    etcd:${EtcdVersion}
    coredns:${CorednsVersion}
)
for imageName in ${images[@]};
do
    docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/${imageName}
    docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/${imageName} k8s.gcr.io/${imageName}
done

docker image ls

#生成kubeadm-config.yaml文件
kubeadm config print init-defaults > /root/kubeadm-config.yaml

#初始化master节点
#kubeadm init --config /root/kubeadm-config.yaml


#kubectl客户端配置
#mkdir -p $HOME/.kube
#cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
#chown $(id -u):$(id -g) $HOME/.kube/config
