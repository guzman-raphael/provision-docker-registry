#! /bin/bash

echo
echo "-----------------||UPDATE REMOTE SERVER||-----------------"
sudo apt-get update

echo
echo "-----------------||DOCKER DEPENDENCIES||-----------------"
sudo apt-get -y install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

echo
echo "-----------------||ADD DOCKER APT REPO||-----------------"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"

sudo apt-get update

# echo "----CHECK DOCKER VERSIONS AVAILABLE----"
# sudo apt-cache policy docker-ce
# sudo apt-cache policy docker-ce-cli
# sudo apt-cache policy containerd.io
echo
echo "-----------------||INSTALL DOCKER||-----------------"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# echo "----CHECK DOCKER VERSIONS AVAILABLE----"
# sudo apt-cache policy docker.io
# echo "----INSTALL DOCKER----"
# # sudo apt-get install -y docker.io=17.12.1-0ubuntu1
# sudo apt-get install -y docker.io
sudo usermod -aG docker ubuntu

echo
echo "-----------------||INSTALL DOCKER COMPOSE||-----------------"
sudo curl -L "https://github.com/docker/compose/releases/download/1.24.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
docker-compose --version

sg docker -c "sudo -i -u $USER sh /home/ubuntu/ec2-provision2.sh"
# sg docker -c "sudo -i -u $USER sh /home/ubuntu/ec2-provision2.sh $1"
