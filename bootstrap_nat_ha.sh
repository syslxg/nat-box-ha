source ~/workspace/deployments-aws/garyliu/bosh_environment
export AWS_ACCESS_KEY_ID=$BOSH_AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY=$BOSH_AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=us-east-1

az=$BOSH_VPC_PRIMARY_AZ
nat_ami=ami-ad227cc4 #amzn-ami-vpc-nat-pv-2013.09.0.x86_64-ebs
server_ami=ami-2f726546 #Amazon Linux AMI 2014.03

function retry() { while ! eval $@; do sleep 10; echo -e "retry...\n"; done } 
alias ec2='aws ec2'

#vpc
echo "creating vpc for Nat HA Demo"
echo "======================="
vpc=`ec2 create-vpc --cidr-block 10.8.0.0/16 |jq .Vpc.VpcId -r`
echo $vpc 

#subnets
echo "creating subnets"
echo "======================="
subnet_pub_a=`ec2 create-subnet --cidr-block 10.8.0.0/24 --vpc-id $vpc --availability-zone $az | jq .Subnet.SubnetId -r` 
echo $subnet_pub_a

subnet_prv_a=`ec2 create-subnet --cidr-block 10.8.2.0/24 --vpc-id $vpc --availability-zone $az | jq .Subnet.SubnetId -r`
echo $subnet_prv_a

ec2 create-tags --resources $vpc          --tags Key=Name,Value=Nats-HA-Demo
ec2 create-tags --resources $subnet_pub_a --tags Key=Name,Value=Public-a
ec2 create-tags --resources $subnet_prv_a --tags Key=Name,Value=Private-a

#igw
igw=`ec2 create-internet-gateway | jq .InternetGateway.InternetGatewayId -r`
echo $igw
ec2 attach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc 

#sg
echo "creating security group"
echo "======================="
sg=`ec2 create-security-group --group-name nats_demo --description nats_demo --vpc-id $vpc |jq .GroupId -r`
echo $sg

retry ec2 authorize-security-group-ingress --group-id $sg --protocol -1 --from-port 0 --to-port 65535 --cidr 0.0.0.0/0

#instances
echo "launching instances"
echo "======================="

jbox=`ec2 run-instances --image-id    $nat_ami --count 1 --instance-type t1.micro --key-name bosh --security-group-ids $sg --subnet-id $subnet_pub_a \
    --private-ip-address 10.8.0.4 | jq .Instances[0].InstanceId -r`
nat_a=`ec2 run-instances --image-id    $nat_ami --count 1 --instance-type t1.micro --key-name bosh --security-group-ids $sg --subnet-id $subnet_pub_a \
    --private-ip-address 10.8.0.5 | jq .Instances[0].InstanceId -r`
nat_b=`ec2 run-instances --image-id    $nat_ami --count 1 --instance-type t1.micro --key-name bosh --security-group-ids $sg --subnet-id $subnet_pub_a \
    --private-ip-address 10.8.0.6 | jq .Instances[0].InstanceId -r`
server_a=`ec2 run-instances --image-id $server_ami --count 1 --instance-type t1.micro --key-name bosh --security-group-ids $sg --subnet-id $subnet_prv_a \
    --private-ip-address 10.8.2.9 | jq .Instances[0].InstanceId -r`

ec2 modify-instance-attribute --instance-id $nat_a --no-source-dest-check
ec2 modify-instance-attribute --instance-id $nat_b --no-source-dest-check

ec2 create-tags --resources $jbox          --tags Key=Name,Value=Nat_HA_Jumpbox
ec2 create-tags --resources $nat_a         --tags Key=Name,Value=Nat_Box_A
ec2 create-tags --resources $nat_b         --tags Key=Name,Value=Nat_Box_B
ec2 create-tags --resources $server_a      --tags Key=Name,Value=Server_A

#elastic IP
echo "allocating Elastic IPs"
echo "======================="
js=`ec2 allocate-address --domain vpc`
eip_jb=`echo "$js" | jq .PublicIp -r`
eipalloc_jb=`echo "$js" | jq .AllocationId -r`
echo "Jumpbox IP: $eip_jb"

js=`ec2 allocate-address --domain vpc`
eip_nat=`echo "$js" | jq .PublicIp -r`
eipalloc_nat=`echo "$js" | jq .AllocationId -r`
echo "NAT egress IP: $eip_nat"

#attach EIPs
ec2 associate-address --instance-id $jbox --allocation-id $eipalloc_jb
ec2 associate-address --instance-id $nat_a --allocation-id $eipalloc_nat


#route tables
#rt_main=`ec2 describe-route-tables --filter Name=vpc-id,Values=$vpc Name=association.main,Values=true | jq .RouteTables[].RouteTableId -r`
rt_a=`ec2 create-route-table --vpc-id $vpc | jq .RouteTable.RouteTableId -r`
rt_b=`ec2 create-route-table --vpc-id $vpc | jq .RouteTable.RouteTableId -r`
ec2 create-tags --resources $rt_a          --tags Key=Name,Value=RT_A
ec2 create-tags --resources $rt_b          --tags Key=Name,Value=RT_B

#ec2 create-route --route-table-id $rt_main --destination-cidr-block 0.0.0.0/0 --gateway-id $igw
ec2 create-route --route-table-id $rt_a --destination-cidr-block 0.0.0.0/0 --instance-id $nat_a
ec2 create-route --route-table-id $rt_b --destination-cidr-block 0.0.0.0/0 --instance-id $nat_b

ec2 associate-route-table --subnet-id $subnet_prv_a --route-table-id $rt_a

echo "Done"
echo "run 'ssh -A ec2-user@$eip_jb' to play"
echo "run 'nuke' to destroy the demo env"

function nuke() {

  ec2 terminate-instances --instance-ids $jbox $nat_a $nat_b $server_a
  sleep 60
  ec2 release-address --allocation-id $eipalloc_jb
  ec2 release-address --allocation-id $eipalloc_nat

  ec2 delete-security-group --group-id $sg
  ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpc
  ec2 delete-internet-gateway --internet-gateway-id $igw
  ec2 delete-subnet --subnet-id $subnet_pub_a
  ec2 delete-subnet --subnet-id $subnet_prv_a
  retry ec2 delete-vpc --vpc-id $vpc

  unalias ec2
}