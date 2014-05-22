
Prerequisites
-----------
- AWS credential
- a kay pair named `bosh` on AWS
- a IAM role named `nat-ha-controller` on AWS, which allows EC2 full access (will lock down latter)

Usage
------
1  edit `bootstrap_nat_ha.sh` to setup AWS credential
1. `. bootstrap_nat_ha.sh`
1. ssh into the controller: `ssh -A ec2-user@$eip_c`
1. run controller.sh from screen/tmux
1. do some damage to the active nat box, like turning off IP forwording by `sysctl -w net.ipv4.ip_forward=1`, or shut down the instance for a while.
1. watch failover from controller screen and AWS console
1. after done playing, destroy everything by `nuke`

What does the enviroment look like?
------------
- One VPC (10.8.0.0/16)
- Two subnets:
  - public (10.8.0.0/24)
  - private (10.8.2.0/24)
- Four instances:
  - nat box A (10.8.0.5)
  - nat box B (10.8.0.6)
  - controller (10.8.0.8)
  - server A (10.8.2.9)
- One Elastic Network Inteface (10.8.0.7)
- Four Elastic IPs
  - 1 for the eni
  - 1 for controller
  - 1 for box A
  - 1 for box B
- One route table
  - rt A points to the eni for 0.0.0.0/0
