How it works
------------
- Two subnets:
  - public
  - private

- Four instances:
  - nat box A
  - nat box B
  - controller
  - server A

- One Elastic Network Inteface


- Four Elastic IPs
  - 1 for NAT egress address
  - 1 for controller
  - 1 for box A
  - 1 for box B

- One route table
  - rt A points to the eni for 0.0.0.0/0

Usage
------
1. `. bootstrap_nat_ha.sh`
1. ssh into the controller: `ssh -A ec2-user@$eip_c`
1. after done playing, `nuke`
