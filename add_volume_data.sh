#! /bin/bash

#format filesystem (warning will delete! First time only)
# sudo apt-get install -y libguestfs-xfs
sudo apt-get install -y xfsprogs
sudo mkfs -t xfs /dev/xvdf

#create mount-point
sudo mkdir /docker-mnt
#mount device
sudo mount /dev/xvdf /docker-mnt
#change user ownership
sudo chown -R ubuntu:ubuntu /docker-mnt

#Add data
# git clone https://github.com/dimitri-yatsenko/db-programming-with-datajoint.git /docker-mnt
mkdir -p /docker-mnt/docker-registry/data
mkdir -p /docker-mnt/docker-registry/auth
ls -la /docker-mnt


#unmount device
sudo umount /dev/xvdf
