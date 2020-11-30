#############################################################################################################
# Run this script on your ansible server as root user.                                                      #
#                                                                                                           #
# In my case, when I kickstart my new hosts, there's already a default non-root user named "bbills".        #
#                                                                                                           #
# And roots' and bbills' rsa keys are already copied to the new hosts by a kickstart post install script.   #
#                                                                                                           #
# The expect code at the top is for you, in case you haven't already done that.                             #
#                                                                                                           #
# Obviously, you need to personalize the $user variable and other such simple things.                       #
#                                                                                                           #
# You should have already built three servers, kubernetes-master, kubernetes-node01, and kubernetes-node02. #
#                                                                                                           #
# Obviously the ip addresses in the ansible host file will possibly be different in your implementation.    #
#                                                                                                           #
# Created a custom authorized_keys file under /home/bbills/expect_project to copy to the remote servers.    #
#############################################################################################################

#Copy the rsa keys to the cluster hosts

for i in kubernetes-master, kubernetes-node01, kubernetes-node02; do

user="bbills"
password="*********"
server=$i
parameter="StrictHostKeyChecking no"
cat /home/bbills/.ssh/id_rsa.pub > /home/bbills/expect_project/authorized_keys
cat /root/.ssh/id_rsa.pub >> /home/bbills/expect_project/authorized_keys
key="/home/bbills/expect_project/authorized_keys"

scp-key()
{
expect <<EOD
#!/usr/bin/expect -f
set key [lindex $argv 0]
set user [lindex $argv 1]
set server [lindex $argv 2]
set password [lindex $argv 3]
set timeout -1
spawn scp -o "$parameter" $key $user@$server:~/
expect {
        password: {send "$password\r" ; exp_continue}
        eof exit
}
EOD
}


mv-root-key()
{
expect <<EOD
#!/usr/bin/expect -f
set timeout 30
#example of getting arguments passed from command line..
#not necessarily the best practice for passwords though...
set server [lindex $argv 0]
set user [lindex $argv 1]
set pass [lindex $argv 2]
# connect to server via ssh, login, and su to root
send_user "connecting to $server\n"
spawn ssh $user@$server
#login handles cases:
#   login with keys (no user/pass)
#   user/pass
#   login with keys (first time verification)
expect {
  "> " { }
  "$ " { }
  "# " { }
  "assword: " {
        send "$password\n"
        expect {
          "> " { }
          "$ " { }
          "# " { }
        }
  }
  "(yes/no)? " {
        send "yes\n"
        expect {
          "> " { }
          "$ " { }
          "# " { }
        }
  }
  default {
        send_user "Login failed\n"
        exit
  }
}
#example command
#send "ls\n"
send  "sudo su -\r"
expect {
  "> " { }
  "$ " { }
  "# " { }
  {*password for bbills:*} {
        send "$password\n"
        expect {
          "> " { }
          "$ " { }
          "# " { }
        }
  }
}
send  "mkdir -p /home/bbills/.ssh && mkdir -p /root/.ssh && cp /home/bbills/authorized_keys \
/root/.ssh && cp /home/bbills/authorized_keys /home/bbills/.ssh && chown -R bbills:bbills \
/home/bbills/.ssh && /bin/sed -i 's/PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config \
&& chown -R root:root /root/.ssh && sudo systemctl restart sshd\r"
expect {
    "> " {}
    "# " {}
    default {}
}
#login out
send "exit\n"
send "exit\n"
expect {
    "> " {}
    "# " {}
    default {}
}
send_user "finished\n"
EOD
}

scp-key $key $user $server $password
mv-root-key $user $server $password

done

#Login to all three and accept the fingerprint

for i in kubernetes-master, kubernetes-node01, kubernetes-node02; do

user="root"
server=$i

first-login()
{
expect <<EOD
#!/usr/bin/expect
set prompt "#|>|\\\$"
spawn ssh $user@$server
expect {
        #If 'expect' sees '(yes/no )', then it will send 'yes'
        #and continue the 'expect' loop
        "(yes/no)" { send "yes\r";exp_continue}
        #If 'password' seen first, then proceed as such.
        "password"
}
EOD
}
first-login $user $server

user="bbills"
server=$1

first-login()
{
expect <<EOD
#!/usr/bin/expect
set prompt "#|>|\\\$"
spawn ssh $user@$server
expect {
        #If 'expect' sees '(yes/no )', then it will send 'yes'
        #and continue the 'expect' loop
        "(yes/no)" { send "yes\r";exp_continue}
        #If 'password' seen first, then proceed as such.
        "password"
}
EOD
}
first-login $user $server

done

#ssh-copy-id -i ~/.ssh/id_rsa.pub root@kubernetes-master

#ssh-copy-id -i ~/.ssh/id_rsa.pub root@kubernetes-node01

#ssh-copy-id -i ~/.ssh/id_rsa.pub root@kubernetes-node02

#Make your playbook on the ansible server under your home dir

mkdir ~/kube-cluster

tee ~/kube-cluster/hosts <<EOF 

[masters]
kubernetes-master ansible_host=192.168.134.153 ansible_user=root

[workers]
kubernetes-node01 ansible_host=192.168.134.154 ansible_user=root
kubernetes-node02 ansible_host=192.168.134.155 ansible_user=root

[ kubernetes ]
kubernetes-master ansible_host=192.168.134.153 ansible_user=root
kubernetes-node01 ansible_host=192.168.134.154 ansible_user=root
kubernetes-node02 ansible_host=192.168.134.155 ansible_user=root

EOF

ansible kubernetes-master -m shell -a 'useradd centos'

ansible kubernetes -m shell -a 'swapoff -a'

ansible kubernetes -m shell -a 'sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab'

tee ~/kube-cluster/kube-dependencies.yml <<EOF

- hosts: all
  become: yes
  tasks:
   - name: install Docker
     yum:
       name: docker
       state: present
       update_cache: true

   - name: start Docker
     service:
       name: docker
       state: started

   - name: ensure net.bridge.bridge-nf-call-ip6tables is set to 1
     sysctl:
      name: net.bridge.bridge-nf-call-ip6tables
      value: 1
      state: present

   - name: ensure net.bridge.bridge-nf-call-iptables is set to 1
     sysctl:
      name: net.bridge.bridge-nf-call-iptables
      value: 1
      state: present

   - name: add Kubernetes' YUM repository
     yum_repository:
      name: Kubernetes
      description: Kubernetes YUM repository
      baseurl: https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
      gpgkey: https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
      gpgcheck: yes

   - name: install kubelet
     yum:
        name: kubelet-1.10.12
        state: present
        update_cache: true

   - name: install kubeadm
     yum:
        name: kubeadm-1.10.12
        state: present

   - name: start kubelet
     service:
       name: kubelet
       enabled: yes
       state: started

- hosts: kubernetes-master
  become: yes
  tasks:
   - name: install kubectl
     yum:
        name: kubectl-1.10.12
        state: present
        allow_downgrade: yes
	
EOF
	
ansible-playbook -i hosts ~/kube-cluster/kube-dependencies.yml

tee ~/kube-cluster/master.yml <<EOF

- hosts: kubernetes-master
  become: yes
  tasks:
    - name: initialize the cluster
      shell: kubeadm init --pod-network-cidr=10.244.0.0/16 >> cluster_initialized.txt
      args:
        chdir: $HOME
        creates: cluster_initialized.txt

    - name: create .kube directory
      become: yes
      become_user: centos
      file:
        path: $HOME/.kube
        state: directory
        mode: 0755

    - name: copy admin.conf to user's kube config
      copy:
        src: /etc/kubernetes/admin.conf
        dest: /home/centos/.kube/config
        remote_src: yes
        owner: centos

    - name: install Pod network
      become: yes
      become_user: centos
      shell: kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/v0.9.1/Documentation/kube-flannel.yml >> pod_network_setup.txt
      args:
        chdir: $HOME
        creates: pod_network_setup.txt
	
EOF
		
ansible-playbook -i hosts ~/kube-cluster/master.yml

ssh centos@kubernetes-master "kubectl get nodes"

tee ~/kube-cluster/workers.yml <<EOF

- hosts: kubernetes-master
  become: yes
  gather_facts: false
  tasks:
    - name: get join command
      shell: kubeadm token create --print-join-command
      register: join_command_raw

    - name: set join command
      set_fact:
        join_command: "{{ join_command_raw.stdout_lines[0] }}"

- hosts: workers
  become: yes
  tasks:
    - name: join cluster
      shell: "{{ hostvars['master'].join_command }} --ignore-preflight-errors all  >> node_joined.txt"
      args:
        chdir: $HOME
        creates: node_joined.txt
	
EOF

ansible-playbook -i hosts ~/kube-cluster/workers.yml

ssh centos@kubernetes-master "kubectl get nodes && kubectl run nginx --image=nginx --port 80 \
&& kubectl expose deploy nginx --port 80 --target-port 80 --type NodePort && kubectl get services \
&& kubectl delete service nginx && kubectl get services && kubectl delete deployment nginx && \
kubectl get deployments"

#should see:

#No resources found.
