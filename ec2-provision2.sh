#! /bin/bash

echo
echo "-----------------||CLONE REGISTRY REPO||-----------------"
mkdir /home/ubuntu/docker-registry
git clone https://github.com/guzman-raphael/docker-registry.git /home/ubuntu/docker-registry

echo
echo "-----------------||START REGISTRY||-----------------"
cd /home/ubuntu/docker-registry
docker-compose up --build -d
