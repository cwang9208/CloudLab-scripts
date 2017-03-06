#!/bin/bash

# !!! Assuming machine type m510 !!!

# Variables
OS_VER="ubuntu`lsb_release -r | cut -d":" -f2 | xargs`"
MLNX_OFED="MLNX_OFED_LINUX-3.4-1.0.0.0-$OS_VER-x86_64"
SHARED_HOME="/shome"
USERS="root `ls /users`"
NUM_CPUS=$(lscpu -p=cpu | grep '[0-9]' | wc -l)

# Test if startup service has run before.
if [ -f /local/startup_service_done ]; then
    # Configurations that need to be (re)done after each reboot

    # Disabled hyperthreading by forcing cores 8 .. 15 offline
    for N in $(seq $((NUM_CPUS/2)) $((NUM_CPUS-1))); do
        echo 0 > /sys/devices/system/cpu/cpu$N/online
    done

    # Set CPU scaling governor to "performance"
    # Note: the effect `cpupower frequency-set -g performance` doesn't seem to persist?
    for N in $(seq 0 $((NUM_CPUS/2-1)))); do
        echo performance > /sys/devices/system/cpu/cpu$N/cpufreq/scaling_governor
    done

    # Sometimes (e.g. after each experiment extension) the CloudLab management
    # software will replace our authorized_keys settings; restore our settings
    # automatically after reboot.
    for user in $USERS; do
        if [ "$user" = "root" ]; then
            ssh_dir=/root/.ssh
        else
            ssh_dir=/users/$user/.ssh
        fi

        if [ -f $ssh_dir/authorized_keys.old ]; then
            mv $ssh_dir/authorized_keys.old $ssh_dir/authorized_keys
        fi
    done

    exit 0
fi

# Install common utilities
apt-get update
apt-get --assume-yes install mosh vim tmux pdsh tree axel

# NFS
apt-get --assume-yes install nfs-kernel-server nfs-common

# cpupower, etc.
kernel_release=`uname -r`
apt-get --assume-yes install linux-tools-common linux-tools-${kernel_release}

# Install RAMCloud dependencies
apt-get --assume-yes install build-essential git-core doxygen libpcre3-dev \
        protobuf-compiler libprotobuf-dev libcrypto++-dev libevent-dev \
        libboost-all-dev libgtest-dev libzookeeper-mt-dev zookeeper \
        libssl-dev default-jdk ccache

# Install numpy, scipy, matplotlib and docopt
apt-get --assume-yes install python-numpy python-scipy python-docopt \
        python-matplotlib

# Setup password-less ssh between nodes
for user in $USERS; do
    if [ "$user" = "root" ]; then
        ssh_dir=/root/.ssh
    else
        ssh_dir=/users/$user/.ssh
    fi
    /usr/bin/geni-get key > $ssh_dir/id_rsa
    chmod 600 $ssh_dir/id_rsa
    chown $user: $ssh_dir/id_rsa
    ssh-keygen -y -f $ssh_dir/id_rsa > $ssh_dir/id_rsa.pub
    cat $ssh_dir/id_rsa.pub >> $ssh_dir/authorized_keys
    chmod 644 $ssh_dir/authorized_keys
    cat >>$ssh_dir/config <<EOL
    Host *
         StrictHostKeyChecking no
EOL
    chmod 644 $ssh_dir/config
done

# Change user login shell to Bash
for user in `ls /users`; do
    chsh -s `which bash` $user
done

# Fix "rcmd: socket: Permission denied" when using pdsh
echo ssh > /etc/pdsh/rcmd_default

hostname=`hostname --short`
if [ "$hostname" = "rcnfs" ]; then
    # In `cloudlab-profile.py`, we already asked for a temporary file system
    # mounted at /shome.
    chmod 777 $SHARED_HOME
    echo "$SHARED_HOME *(rw,sync,no_root_squash)" >> /etc/exports

    # TODO: HOW TO START THE SERVICE AUTOMATICALLY AFTER REBOOT?
    /etc/init.d/nfs-kernel-server start

    # Download Mellanox OFED package
    cd $SHARED_HOME
    axel -n 8 -q http://www.mellanox.com/downloads/ofed/MLNX_OFED-3.4-1.0.0.0/$MLNX_OFED.tgz
    tar xzf $MLNX_OFED.tgz

    # Generate a list of machines in the cluster
    > rc-hosts.txt
    let num_rcxx=$(geni-get manifest | grep -o "<node " | wc -l)-2
    for i in $(seq "$num_rcxx")
    do
        printf "rc%02d\n" $i >> rc-hosts.txt
    done
    printf "rcmaster\n" >> rc-hosts.txt
    printf "rcnfs\n" >> rc-hosts.txt

    # Mark the startup service has finished
    > /local/startup_service_done
else
    # Enable hugepage support: http://dpdk.org/doc/guides/linux_gsg/sys_reqs.html
    # The changes will take effects after reboot. m510 is not a NUMA machine.
    # Reserve 1GB hugepages via kernel boot parameters
    kernel_boot_params+="hugepagesz=1G hugepages=4"
    # Or, 2MB hugepages after the system boots
    # echo vm.nr_hugepages=1024 >> /etc/sysctl.conf
    mkdir /mnt/huge
    chmod 777 /mnt/huge
    echo "nodev /mnt/huge hugetlbfs defaults 0 0" >> /etc/fstab

    # Enable cpuset functionality if it's not been done yet.
    if [ ! -d "/sys/fs/cgroup/cpuset" ]; then
        mount -t tmpfs cgroup_root /sys/fs/cgroup
        mkdir /sys/fs/cgroup/cpuset
        mount -t cgroup cpuset -o cpuset /sys/fs/cgroup/cpuset/
    fi

    # Wait until rcnfs is properly set up
    while [ "$(ssh rcnfs "[ -f /local/startup_service_done ] && echo 1 || echo 0")" != "1" ]; do
        sleep 1
    done

    # NFS clients setup: use the publicly-routable IP addresses for both the server
    # and the clients to avoid interference with the experiment.
    rcnfs_ip=`ssh rcnfs "hostname -i"`
    mkdir $SHARED_HOME; mount -t nfs4 $rcnfs_ip:$SHARED_HOME $SHARED_HOME
    echo "$rcnfs_ip:$SHARED_HOME $SHARED_HOME nfs4 rw,sync,hard,intr,addr=`hostname -i` 0 0" >> /etc/fstab

    # Isolate certain cpus from kernel scheduling and put them into full
    # dynticks mode (need reboot to take effect)
    isolcpus="2"
    kernel_boot_params+="isolcpus=$isolcpus nohz_full=$isolcpus rcu_nocbs=$isolcpus"

    # Update GRUB with our kernel boot parameters
    grub-install /dev/nvme0n1
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$kernel_boot_params /" /etc/default/grub
    update-grub
    # TODO: VERIFY THE OPTIONS WORK? http://www.breakage.org/2013/11/15/nohz_fullgodmode/

    # Install Mellanox OFED (need reboot to work properly). Note: attempting to build
    # MLNX DPDK before installing MLNX OFED may result in compile-time errors.
    $SHARED_HOME/$MLNX_OFED/mlnxofedinstall --force --without-fw-update

    # Mark the startup service has finished
    > /local/startup_service_done

    # Reboot to let the configuration take effects
    reboot
fi

