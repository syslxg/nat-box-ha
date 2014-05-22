subnet=SUBNETID_PLACE_HOLDER
probe=10.8.2.9

function check_env
{
	descr_nic=`ec2dnic --filter tag:Name=Floating_NIC --filter subnet-id=$subnet `
	eni=`echo "$descr_nic" |grep NETWORKINTERFACE |awk '{print $2}'`
	eip=`echo "$descr_nic" |grep ASSOCIATION |awk '{print $2}'`
	ip_eni=`echo "$descr_nic" |grep PRIVATEIPADDRESS |awk '{print $2}'`
	echo "Floating_NIC: $eni, $eip"

	descr_a=`ec2din --filter tag:Name=Nat_Box_A --filter subnet-id=$subnet`
	id_a=`echo "$descr_a" |grep INSTANCE | awk '{print $2}'`
	ip_a=`echo "$descr_a" |grep PRIVATEIPADDRESS |grep -v "$ip_eni" |awk '{print $2}'`
	echo "Nat_Box_A: $id_a, $ip_a"

	descr_b=`ec2din --filter tag:Name=Nat_Box_B --filter subnet-id=$subnet`
	id_b=`echo "$descr_b" |grep INSTANCE |awk '{print $2}'`
	ip_b=`echo "$descr_b" |grep PRIVATEIPADDRESS |grep -v "$ip_eni" |awk '{print $2}'`
	echo "Nat_Box_B: $id_b, $ip_b"
}

function is_up () {
	ping -c 3 $1 2>&1 >/dev/null && return 0 || ( send_notice; return 1)
}

function send_notice {
	echo "sending notice to cloudops"
}

function failover () {
        echo "fail over to $1"
	if [ -ne "$attach_id" ]; then
		ec2-detach-network-interface $attach_id  -f
		sleep 10
	fi
	ec2-attach-network-interface $eni -i $1  -d 1
}

function detect_and_recover
{
	descr_nic=`ec2dnic --filter tag:Name=Floating_NIC,subnet=$subnet`
	id_active=`echo "$descr_nic" |grep ATTACHMENT |awk '{print $2}'`
	attach_id=`echo "$descr_nic" |grep ATTACHMENT |awk '{print $3}' `
	if [ "$id_active" == "$id_a" ]; then
		echo "Floating_NIC is on Box_A"
		id_standby=$id_b
		ip_standby=$ip_b
	elif [ "$id_active" == "$id_b" ]; then
		echo "Floating_NIC is on Box_B"
		id_standby=$id_a
		ip_standby=$ip_a
	elif [ -z "$id_active" ]; then
		echo "Floating_NIC is not attached"
		id_standby=$id_b
		ip_standby=$ip_b
	else
		echo "Floating_NIC attached to wrong instance"
		return
	fi

	if !(is_up $ip_standby && is_up $probe); then
		echo "standby node or the probe node is down"
		return
	fi

	echo "check egress ip by talking to host $probe"
	actual_egress_ip=`ssh -o StrictHostKeyChecking=no $probe "curl --connect-timeout 10 -s ifconfig.me"`
	if [ "$actual_egress_ip" == "$eip" ]; then
		echo "NAT box $id_active works fine"
		return
	else
		echo "NAT box $id_active is not working"
		failover $id_standby
	fi
}


. /etc/profile.d/aws-apitools-common.sh
check_env
while : ; do
        detect_and_recover
        sleep 300
done
