#!/usr/bin/env /bin/sh
export PATH=$PATH:/root/.local/bin
ZONE_NAME=${URL}

CLUSTER_NAME=${SUBDOMAINS}.${ZONE_NAME}

main() {
    install_depen
    detach_volume
    teardown_host
    # destroy_volume
    provision_host
    # create_volume
    attach_volume
    remote_start_registry
}   

install_depen() {
    echo
    echo "-----------------|INSTALL APT PKGS|-----------------"
    apk update
    apk add curl jq openssh
    rm -R /root/.ssh
    mkdir /root/.ssh
    ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""

    echo
    echo "-----------------|INSTALL AWS CLI|-----------------"
    pip install awscli --upgrade --user
    export PATH=$PATH:/root/.local/bin
    aws --version
}

teardown_host() {
    # #gen key pair
    echo
    echo "-----------------|DELETE KEYS|-----------------"
    aws ec2 delete-key-pair --key-name docker-mgmt
    rm docker-mgmt.pem
    rm docker-mgmt.pem.pub
    rm ssh_config

    echo
    echo "-----------------|REMOVE EXPOSED DOMAIN ALIAS|-----------------"
    HZ_ID=$(aws route53 list-hosted-zones | jq -r '.HostedZones[] | select(.Name|test("'$ZONE_NAME'")) | .Id')
    HZ_ID=$(echo $HZ_ID | awk -F '/' '{print $3}')
    tmp=$(mktemp)
    jq ".Changes[0].Action = \"DELETE\" | .Changes[0].ResourceRecordSet.Name = \"${CLUSTER_NAME}\"" ./add-record-sets.json > "$tmp"
    mv "$tmp" ./add-record-sets.json
    chmod o+rw ./add-record-sets.json
    aws route53 change-resource-record-sets --hosted-zone-id $HZ_ID --change-batch file://./add-record-sets.json

    # # stop prev instances
    echo
    echo "-----------------|REVIEW CURRENT INST|-----------------"
    INST=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=docker-mgmt")
    RES_COUNT=$(echo $INST | jq '.Reservations | length')
    i=0
    while [[ $i -le $(expr $RES_COUNT - 1) ]]
    do
        ST=$(echo $INST | jq -r ".Reservations[$i].Instances[0].State.Name")
        if [ "$ST" == "running" ] 
        then
            echo
            echo "-----------------|ISSUE STOP INST|-----------------"
            ID=$(echo $INST | jq -r ".Reservations[$i].Instances[0].InstanceId")
            NET_ID=$(echo $INST | jq -r ".Reservations[$i].Instances[0].NetworkInterfaces[0].NetworkInterfaceId")
            aws ec2 stop-instances --instance-ids $ID

            STATE=$(aws ec2 describe-instances --instance-ids $ID | jq -r '.Reservations[0].Instances[0].State.Name')
            echo
            echo "-----------------|WAIT FOR INST|-----------------"
            while [ "$STATE" != "stopped" ]
            do
                STATE=$(aws ec2 describe-instances --instance-ids $ID | jq -r '.Reservations[0].Instances[0].State.Name')
            done
            # terminate once stopped instances
            echo
            echo "-----------------|TERMINATE INST|-----------------"
            aws ec2 terminate-instances --instance-ids $ID

            echo
            echo "-----------------|MONITOR NETWORK INTERFACE OF INST|-----------------"
            STATE=$(aws ec2 describe-network-interfaces --network-interface-id $NET_ID | jq -r '.NetworkInterfaces[0].Status')
            echo
            echo "-----------------|WAIT NETWORK INTERFACE AVAILABLE|-----------------"
            while [ "$STATE" != "available" ] && [ "$STATE" != "null" ]
            do
                # echo $STATE
                STATE=$(aws ec2 describe-network-interfaces --network-interface-id $NET_ID | jq -r '.NetworkInterfaces[0].Status')
            done

            echo
            echo "-----------------|REMOVE NETWORK INTERFACE OF INST|-----------------"
            aws ec2 delete-network-interface --network-interface-id $NET_ID
        fi
        i=$(expr $i + 1)
    done

    VPC_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=docker-mgmt | jq -r '.SecurityGroups[0].VpcId')
    SUB_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" | jq -r '.Subnets[0].SubnetId')
    IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" | jq -r '.InternetGateways[0].InternetGatewayId')

    echo
    echo "-----------------|RELEASE ELASTIC IP|-----------------"
    PREV_EIP_ID=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=docker-mgmt" | jq -r '.Addresses[0].AllocationId')
    aws ec2 release-address --allocation-id $PREV_EIP_ID

    echo
    echo "-----------------|REMOVE DOCKER GRP RULES|-----------------"
    GRP_MGMT_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=docker-mgmt | jq -r '.SecurityGroups[0].GroupId')
    aws ec2 revoke-security-group-ingress --group-id $GRP_MGMT_ID --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}] IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}] IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]

    echo
    echo "-----------------|DELETE MGMT GRP|-----------------"
    aws ec2 delete-security-group --group-id $GRP_MGMT_ID  #mgmt

    echo
    echo "-----------------|DELETE SUBNET|-----------------"
    aws ec2 delete-subnet --subnet-id $SUB_ID

    echo
    echo "-----------------|DELETE IGW|-----------------"
    aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
    aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID

    echo
    echo "-----------------|DELETE PREVIOUS VPC|-----------------"
    aws ec2 delete-vpc --vpc-id $VPC_ID
}

provision_host() {
    echo
    echo "-----------------|CREATE KEY|-----------------"
    ssh-keygen -t rsa -C "docker-mgmt" -f ./docker-mgmt.pem -N ""
    aws ec2 import-key-pair --key-name "docker-mgmt" --public-key-material file://./docker-mgmt.pem.pub

    echo "-----------------|CREATE VPC|-----------------"
    VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 | jq -r '.Vpc.VpcId')
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"

    echo
    echo "-----------------|CREATE IGW|-----------------"
    IGW_ID=$(aws ec2 create-internet-gateway | jq -r '.InternetGateway.InternetGatewayId')
    aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

    echo
    echo "-----------------|MOD ROUTE TABLES|-----------------"
    ROUTE_ID=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID | jq -r '.RouteTables[0].RouteTableId')
    aws ec2 create-route --route-table-id $ROUTE_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

    echo
    echo "-----------------|CREATE SUBNET|-----------------"
    SUB_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.0.0/16 --availability-zone us-east-2b | jq -r '.Subnet.SubnetId')
        
    echo
    echo "-----------------|CREATE DOCKER GRP|-----------------"
    GRP_MGMT_ID=$(aws ec2 create-security-group --group-name docker-mgmt --vpc-id $VPC_ID --description main | jq -r '.GroupId')

    echo
    echo "-----------------|ALLOW TRAFFIC|-----------------"
    aws ec2 authorize-security-group-ingress --group-id $GRP_MGMT_ID --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}] IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}] IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]

    echo
    echo "-----------------|CREATE ELASTIC IP|-----------------"
    EIP_ID=$(aws ec2 allocate-address --domain vpc | jq -r '.AllocationId')
    aws ec2 create-tags --resources $EIP_ID --tags Key=Name,Value=docker-mgmt
    DNS_IP=$(aws ec2 describe-addresses --allocation-ids $EIP_ID | jq -r '.Addresses[0].PublicIp')

    echo 
    echo "-----------------|UPDATE ROUTES|-----------------"
    HZ_ID=$(aws route53 list-hosted-zones | jq -r '.HostedZones[] | select(.Name|test("'$ZONE_NAME'")) | .Id')
    HZ_ID=$(echo $HZ_ID | awk -F '/' '{print $3}')
    
    tmp=$(mktemp)
    jq ".Changes[0].Action = \"UPSERT\" | .Changes[0].ResourceRecordSet.Name = \"${CLUSTER_NAME}\" | .Changes[0].ResourceRecordSet.ResourceRecords[0].Value = \"${DNS_IP}\"" ./add-record-sets.json > "$tmp"
    mv "$tmp" ./add-record-sets.json
    chmod o+rw ./add-record-sets.json

    aws route53 change-resource-record-sets --hosted-zone-id $HZ_ID --change-batch file://./add-record-sets.json
    # sudo systemd-resolve --flush-caches

    echo
    echo "-----------------|CREATE INST|-----------------"
    #ubuntu server
    INT_ID=$(aws ec2 run-instances --image-id ami-0c55b159cbfafe1f0 --security-group-ids $GRP_MGMT_ID --subnet-id $SUB_ID --associate-public-ip-address --count 1 --instance-type t2.micro --key-name docker-mgmt --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=docker-mgmt}]' | jq -r '.Instances[0].InstanceId')
    STATE=$(aws ec2 describe-instances --instance-ids $INT_ID | jq -r '.Reservations[0].Instances[0].State.Name')

    echo
    echo "-----------------|WAIT FOR INST|-----------------"
    while [ "$STATE" != "running" ]
    do
        STATE=$(aws ec2 describe-instances --instance-ids $INT_ID | jq -r '.Reservations[0].Instances[0].State.Name')
    done

    echo
    echo "-----------------|ASSOCIATE ELASTIC IP|-----------------"
    aws ec2 associate-address --instance-id $INT_ID --allocation-id $EIP_ID

    echo
    echo "-----------------|CONN DETAILS|-----------------"
    OBJ=$(aws ec2 describe-instances --instance-ids $INT_ID)
    DNS=$(echo $OBJ | jq -r '.Reservations[0].Instances[0].PublicDnsName')
    DNS_IP=$(echo $OBJ | jq -r '.Reservations[0].Instances[0].PublicIpAddress')
    PRIV_IP=$(echo $OBJ | jq -r '.Reservations[0].Instances[0].PrivateIpAddress')

    echo "Server running: $INT_ID"
    echo "Public DNS: $DNS"
    echo "Public IP: $DNS_IP"
    
    echo
    echo "-----------------|CREATE CONN FILE|-----------------"
    cat >>./ssh_config <<EOL
Host docker
    HostName ${CLUSTER_NAME}
    Port 22
    User ubuntu
    IdentityFile docker-mgmt.pem
    StrictHostKeyChecking no
    ConnectionAttempts 1000
EOL

}

create_volume() {
    echo 
    echo "-----------------|CREATE EBS VOLUME|-----------------"
    # First time only
    AVAIL_ZONE=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=docker-mgmt" | jq -r '.Reservations[].Instances[] | select(.State.Name|test("running")) | .Placement.AvailabilityZone')
    V_ID=$(aws ec2 create-volume --size 15 --region us-east-2 --availability-zone $AVAIL_ZONE --volume-type gp2 --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=docker-data}]' | jq -r '.VolumeId')

    STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
    while [ "$STATE" != "available" ]
    do
        STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
    done

    # V_ID=$(aws ec2 describe-volumes --filters Name=tag:Name,Values=shared | jq -r '.Volumes[0].VolumeId')
    MACHINE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=docker-mgmt" | jq -r '.Reservations[].Instances[] | select(.State.Name|test("running")) | .InstanceId')
    # attach
    aws ec2 attach-volume --volume-id $V_ID --instance-id $MACHINE_ID --device /dev/sdf

    # init
    scp -F ./ssh_config ./add_volume_data.sh docker:/home/ubuntu/add_volume_data.sh
    ssh -F ./ssh_config docker "sh /home/ubuntu/add_volume_data.sh"

    # detach
    aws ec2 detach-volume --volume-id $V_ID
    STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
    while [ "$STATE" != "available" ]
    do
        STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
    done
}

attach_volume() {
    echo 
    echo "-----------------|ATTACH EBS VOLUME|-----------------"
    V_ID=$(aws ec2 describe-volumes --filters Name=tag:Name,Values=docker-data | jq -r '.Volumes[0].VolumeId')
    MACHINE_ID=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=docker-mgmt" | jq -r '.Reservations[].Instances[] | select(.State.Name|test("running")) | .InstanceId')
    # attach
    aws ec2 attach-volume --volume-id $V_ID --instance-id $MACHINE_ID --device /dev/sdf
    STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
    while [ "$STATE" != "in-use" ]
    do
        STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
    done

    # mount
    scp -F ./ssh_config ./attach_volume.sh docker:/home/ubuntu/attach_volume.sh
    ssh -F ./ssh_config docker "sh /home/ubuntu/attach_volume.sh"
}

detach_volume() {
    echo 
    echo "-----------------|DETACH EBS VOLUME|-----------------"
    V_ID=$(aws ec2 describe-volumes --filters Name=tag:Name,Values=docker-data | jq -r '.Volumes[0].VolumeId')

    STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
    if [ "$STATE" != "available" ]
    then
        # unmount
        ssh -F ./ssh_config docker "sudo umount /dev/xvdf"

        # detach
        aws ec2 detach-volume --volume-id $V_ID

        if [ ! -z "$V_ID" ] && [ "$V_ID" != "null" ]
        then
            STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
            while [ "$STATE" != "available" ]
            do
                STATE=$(aws ec2 describe-volumes --volume-ids $V_ID | jq -r '.Volumes[0].State')
            done
        fi
    fi
   
}

destroy_volume() {
    echo 
    echo "-----------------|DESTROY EBS VOLUME|-----------------"
    V_ID=$(aws ec2 describe-volumes --filters Name=tag:Name,Values=docker-data | jq -r '.Volumes[0].VolumeId')
    aws ec2 delete-volume --volume-id $V_ID
}

remote_start_registry() {
    echo 
    echo "-----------------|INSTAL REMOTE DEPENDENCIES|-----------------"
    # issue with adding to known hosts, noise in log
    scp -F ./ssh_config ./ec2-provision1.sh docker:/home/ubuntu/ec2-provision1.sh
    scp -F ./ssh_config ./ec2-provision2.sh docker:/home/ubuntu/ec2-provision2.sh

    exec 5>&1
    OUT=$(ssh -F ./ssh_config docker "sh /home/ubuntu/ec2-provision1.sh"|tee /dev/fd/5)
}


run() {
    printf '\ec'
    date
    START_TIME=$(date -u +%s)
    main
    ELAPSED_TIME=$(($(date -u +%s) - $START_TIME))
    echo "Total Execution Time: ${ELAPSED_TIME}[s]"
    date
}

"$@"
