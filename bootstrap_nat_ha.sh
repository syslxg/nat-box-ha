source ~/workspace/deployments-aws/garyliu/bosh_environment
export AWS_ACCESS_KEY_ID=$BOSH_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$BOSH_AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=us-east-1

az=$BOSH_VPC_PRIMARY_AZ
nat_ami=ami-ad227cc4 #amzn-ami-vpc-nat-pv-2013.09.0.x86_64-ebs
server_ami=ami-2f726546 #Amazon Linux AMI 2014.03

function retry() {
	i=3
	while [ $i -ge 1 ] ; do
	  eval $@ && break;
	  i=$((i-1))
	  sleep 20
	  echo -e "retry...\n"
	done
}

function start_phase () {
	echo -e "\n=== $1 ===\n"
}


alias ec2='retry aws ec2'
alias ec2t='retry aws --output text ec2'
alias jq='jq -r'

#vpc
start_phase "creating vpc"
vpc=`ec2 create-vpc --cidr-block 10.8.0.0/16 |jq .Vpc.VpcId `
echo $vpc

#subnets
start_phase "creating subnets"
subnet_pub_a=`ec2 create-subnet --cidr-block 10.8.0.0/24 --vpc-id $vpc --availability-zone $az | jq .Subnet.SubnetId `
echo "public subnet: $subnet_pub_a"

subnet_prv_a=`ec2 create-subnet --cidr-block 10.8.2.0/24 --vpc-id $vpc --availability-zone $az | jq .Subnet.SubnetId `
echo "private subnet: $subnet_prv_a"

ec2t create-tags --resources $vpc          --tags Key=Name,Value=Nats-HA-Demo
ec2t create-tags --resources $subnet_pub_a --tags Key=Name,Value=Public-a
ec2t create-tags --resources $subnet_prv_a --tags Key=Name,Value=Private-a

#igw
igw=`ec2 create-internet-gateway | jq .InternetGateway.InternetGatewayId `
echo $igw
ec2t attach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc

#sg
start_phase "creating security group"
sg=`ec2 create-security-group --group-name nats_demo --description nats_demo --vpc-id $vpc |jq .GroupId `
echo $sg

ec2t authorize-security-group-ingress --group-id $sg --protocol -1 --from-port 0 --to-port 65535 --cidr 0.0.0.0/0

#instances
start_phase "launching instances"

controller=`ec2 run-instances --image-id $nat_ami --count 1 --instance-type t1.micro --key-name bosh --security-group-ids $sg --subnet-id $subnet_pub_a \
    --private-ip-address 10.8.0.8 --iam-instance-profile Name=nat-ha-controller | jq .Instances[0].InstanceId `
nat_a=`ec2 run-instances --image-id $nat_ami --count 1 --instance-type t1.micro --key-name bosh --security-group-ids $sg --subnet-id $subnet_pub_a \
    --private-ip-address 10.8.0.5 --user-data file://user_data_nat.txt | jq .Instances[0].InstanceId `
nat_b=`ec2 run-instances --image-id $nat_ami --count 1 --instance-type t1.micro --key-name bosh --security-group-ids $sg --subnet-id $subnet_pub_a \
    --private-ip-address 10.8.0.6 --user-data file://user_data_nat.txt | jq .Instances[0].InstanceId `
server_a=`ec2 run-instances --image-id $server_ami --count 1 --instance-type t1.micro --key-name bosh --security-group-ids $sg --subnet-id $subnet_prv_a \
    --private-ip-address 10.8.2.9 | jq .Instances[0].InstanceId `

ec2t modify-instance-attribute --instance-id $nat_a --no-source-dest-check
ec2t modify-instance-attribute --instance-id $nat_b --no-source-dest-check

ec2t create-tags --resources $controller    --tags Key=Name,Value=Nat_HA_Control
ec2t create-tags --resources $nat_a         --tags Key=Name,Value=Nat_Box_A
ec2t create-tags --resources $nat_b         --tags Key=Name,Value=Nat_Box_B
ec2t create-tags --resources $server_a      --tags Key=Name,Value=Server_A

#elastic IP
start_phase "allocating Elastic IPs"
js=`ec2 allocate-address --domain vpc`
eip_c=`echo "$js" | jq .PublicIp `
eipalloc_c=`echo "$js" | jq .AllocationId`

js=`ec2 allocate-address --domain vpc`
eip_nat=`echo "$js" | jq .PublicIp `
eipalloc_nat=`echo "$js" | jq .AllocationId`

js=`ec2 allocate-address --domain vpc`
eip_a=`echo "$js" | jq .PublicIp `
eipalloc_a=`echo "$js" | jq .AllocationId`

js=`ec2 allocate-address --domain vpc`
eip_b=`echo "$js" | jq .PublicIp `
eipalloc_b=`echo "$js" | jq .AllocationId`
echo "NAT egress IP: $eip_nat"
echo "Controller IP: $eip_c"

#ENI
start_phase "creating Elastic NIC"
floating_nic=`ec2 create-network-interface --subnet-id $subnet_pub_a --private-ip-address 10.8.0.7 --group $sg | jq .NetworkInterface.NetworkInterfaceId`
ec2t create-tags --resources $floating_nic --tags Key=Name,Value=Floating_NIC
ec2t  modify-network-interface-attribute --network-interface-id $floating_nic --source-dest-check false

#attach EIPs
ec2t associate-address --instance-id $controller --allocation-id $eipalloc_c
ec2t associate-address --instance-id $nat_a --allocation-id $eipalloc_a
ec2t associate-address --instance-id $nat_b --allocation-id $eipalloc_b
ec2t associate-address --network-interface-id $floating_nic --allocation-id $eipalloc_nat --allow-reassociation
ec2t attach-network-interface --network-interface-id $floating_nic --instance-id $nat_a --device-index 1

#route tables
rt_main=`ec2 describe-route-tables --filter Name=vpc-id,Values=$vpc Name=association.main,Values=true | jq .RouteTables[].RouteTableId `
rt_a=`ec2 create-route-table --vpc-id $vpc | jq .RouteTable.RouteTableId `
ec2t create-tags --resources $rt_a          --tags Key=Name,Value=RT_A

ec2t create-route --route-table-id $rt_main --destination-cidr-block 0.0.0.0/0 --gateway-id $igw
ec2t create-route --route-table-id $rt_a --destination-cidr-block 0.0.0.0/0 --network-interface-id $floating_nic

ec2t associate-route-table --subnet-id $subnet_prv_a --route-table-id $rt_a

#render controller.sh
start_phase "uploading controller script"
sed "s/SUBNETID_PLACE_HOLDER/$subnet_pub_a/" controller.sh > controller
echo "waiting for ssh port"
retry "sleep 30; ssh -o BatchMode=yes -o StrictHostKeyChecking=no ec2-user@$eip_c uptime"
scp controller ec2-user@$eip_c:~/controller.sh || echo "failed uploading controller.sh to controller. Please upload it manually."

echo "Done"
echo "run 'ssh -A ec2-user@$eip_c' to play"
echo "run 'nuke' to destroy the demo env"

function nuke() {
  ec2t terminate-instances --instance-ids $controller $nat_a $nat_b $server_a
  sleep 60
  ec2t delete-network-interface --network-interface-id $floating_nic
  ec2t release-address --allocation-id $eipalloc_c
  ec2t release-address --allocation-id $eipalloc_nat
  ec2t release-address --allocation-id $eipalloc_a
  ec2t release-address --allocation-id $eipalloc_b

  ec2t delete-security-group --group-id $sg
  ec2t detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc
  ec2t delete-internet-gateway --internet-gateway-id $igw
  ec2t delete-subnet --subnet-id $subnet_pub_a
  ec2t delete-subnet --subnet-id $subnet_prv_a
  ec2t delete-route-table --route-table-id $rt_a
  ec2t delete-vpc --vpc-id $vpc || echo "please delete remaining stuff manually from AWS console"
}
