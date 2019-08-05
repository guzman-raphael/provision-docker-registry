#! /bin/bash

#create mount-point
sudo mkdir /docker-mnt
#mount device
sudo mount /dev/xvdf /docker-mnt
#change user ownership
sudo chown -R ubuntu:ubuntu /docker-mnt

#configure auto-mount on restart
BLK_UUID=$(sudo blkid | grep xvdf | awk '{print $2}' | awk -F '"' '{print $2}')
echo "UUID=$BLK_UUID  /docker-mnt  xfs  defaults,nofail  0  2" | sudo tee -a /etc/fstab
