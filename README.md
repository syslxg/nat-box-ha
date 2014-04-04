How it works
------------
2 subnets:
- public
- private

4 instances:
nat box A
nat box B
controller
server A

2 Elastic IPs
- 1 for NAT egress address
- 1 for controller

2 route tables
- rt A points to nat box A
- rt B points to nat box B



Usage
------
1. `. bootstrap_nat_ha.sh`
1. ssh into the controller: `ssh -A ec2-user@$eip_c`
1. after done playing, `nuke`
