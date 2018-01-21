provider "aws" {
	region = "${var.aws_region}"
	profile = "${var.aws_profile}"
}

# VPC

resource "aws_vpc" "lab" {
	cidr_block = "10.1.0.0/16"
}

# Internet Gateway

resource "aws_internet_gateway" "lab_ig" {
	vpc_id = "${aws_vpc.lab.id}"
}

# Route tables

resource "aws_route_table" "lab_public" {
	vpc_id = "${aws_vpc.lab.id}"
	route {
		cidr_block = "0.0.0.0/0"
		gateway_id = "${aws_internet_gateway.lab_ig.id}"
		}
	tags {
		Name = "public"
	}
}

resource "aws_default_route_table" "lab_private" {
	default_route_table_id = "${aws_vpc.lab.default_route_table_id}"
	tags {
		Name = "private"
	}
}

# Subnets

resource "aws_subnet" "lab_public" {
	vpc_id = "${aws_vpc.lab.id}"
	cidr_block = "10.1.1.0/24"
	map_public_ip_on_launch = true
	availability_zone = "eu-west-2a"
	tags {
		Name = "public"
	}
}

resource "aws_subnet" "lab_private" {
	vpc_id = "${aws_vpc.lab.id}"
	cidr_block = "10.1.2.0/24"
	map_public_ip_on_launch = false
	availability_zone = "eu-west-2b"
	tags {
		Name = "private"
	}
}

# S3 VPC endpoint

resource "aws_vpc_endpoint" "private-s3" {
	vpc_id = "${aws_vpc.lab.id}"
	service_name = "com.amazonaws.${var.aws_region}.s3"
	route_table_ids = ["${aws_vpc.lab.main_route_table_id}", "${aws_route_table.lab_public.id}"]
	policy = <<POLICY
{
	"Statement": [
		{
			"Action": "*",
			"Effect": "Allow",
			"Resource": "*",
			"Pricipal": "*"
		}
	]
}
POLICY
}

# RDS Subnet

resource "aws_subnet" "lab_rds" {
	vpc_id = "${aws_vpc.lab.id}"
	cidr_block = "10.1.3.0/24"
	map_public_ip_on_launch = false
	availability_zone = "eu-west-2c"
	tags {
		Name = "rds"
	}
}

# Subnet Associations

resource "aws_route_table_association" "lab_public_assoc" {
	subnet_id = "${aws_subnet.lab_public.id}"
	route_table_id = "${aws_route_table.lab_public.id}"
}

resource "aws_route_table_association" "lab_private_assoc" {
	subnet_id = "${aws_subnet.lab_private.id}"
	route_table_id = "${aws_default_route_table.lab_private.id}"
}

resource "aws_db_subnet_group" "lab_rds_subnetgroup" {
	name = "lab_rds_subnetgroup"
	subnet_ids = ["${aws_subnet.lab_rds.id}"]
	tags {
		Name = "rds_sng"
	}
}

# Public Security Groups

resource "aws_security_group" "lab_public" {
	name = "sg_public"
	description = "used for public and private instances"
	vpc_id = "${aws_vpc.lab.id}"

	# SSH
	ingress {
		from_port 	= 22
		to_port		= 22
		protocol 	= "tcp"
		cidr_blocks	= ["${var.localip}"]
	}

	# HTTP
	ingress {
		from_port	= 80
		to_port		= 80
		protocol 	= "tcp"
		cidr_blocks	= ["0.0.0.0/0"]
	}

	egress {
		from_port	= 0
		to_port		= 0
		protocol	= "-1"
		cidr_blocks	= ["0.0.0.0/0"]
	}
}

# Private Security Group

resource "aws_security_group" "lab_private" {
	name = "sg_private"
	description = "used for private instances"
	vpc_id = "${aws_vpc.lab.id}"

	# Access from other sec groups
	ingress {
		from_port 	= 0 
		to_port		= 0
		protocol	= "-1"
		cidr_blocks	= ["10.1.0.0/16"]
	}
	
	egress {
		from_port	= 0
		to_port		= 0
		protocol	= "-1"
		cidr_blocks	= ["0.0.0.0/0"]
	}
}

# RDS Security Group

resource "aws_security_group" "lab_rds" {
	name = "sg_rds"
	description = "used for DB instances"
	vpc_id = "${aws_vpc.lab.id}"
	
	# SQL Access from public/private sec groups
	ingress {
		from_port	= 0
		to_port		= 0
		protocol	= "tcp"
		security_groups = ["${aws_security_group.lab_public.id}", "${aws_security_group.lab_private.id}"]
	}
}

# S3 Code Bucket

resource "aws_s3_bucket" "code" {
	bucket = "${var.domain_name}_code1115"
	acl = "private"
	force_destroy = true
	tags {
		Name = "code bucket"
	}
}

# DB

resource "aws_db_instance" "lab_db" {
	allocated_storage	= 10
	engine				= "mysql"
	engine_version		= "5.6.27"
	instance_class		= "${var.db_instance_class}"
	name				= "${var.dbname}"
	username			= "${var.dbuser}"
	password			= "${var.dbpassword}"
	db_subnet_group_name = "${aws_db_subnet_group.lab_rds_subnetgroup.name}"
	vpc_security_group_ids	= ["${aws_security_group.lab_rds.id}"]
}

# Key Pair

resource "aws_key_pair" "auth" {
	key_name = "${var.key_name}"
	public_key = "${file(var.public_key_path)}"
}

# Dev server

resource "aws_instance" "dev" {
	instance_type = "${var.dev_instance_type}"
	ami = "${var.dev_ami}"
	tags {
		Name = "dev"
	}
	key_name = "${aws_key_pair.auth.id}"
	vpc_security_group_ids = ["${aws_security_group.lab_public.id}"]
	iam_instance_profile = "${aws_iam_instance_profile.s3_access.id}"
	subnet_id = "${aws_subnet.lab_public.id}"
	
	provisioner "local-exec" {
		command = <<EOP
cat <<EOF > aws_hosts
[dev]
${aws_instance.dev.public_ip}
[dev:vars]
s3code=${aws_s3_bucket.code.bucket}
EOF
EOP
	}

	provisioner "local-exec" {
		command = "sleep  6m && ansible-playbook -i aws_hosts wordpress.yml"
	}
}

#Load Balancer

resource "aws_elb" "prod" {
	name = "${var.domain_name}-prod-elb"
	subnets = ["${aws_subnet.lab_private.id}:"]
	security_groups = ["${aws_security_group.lab_public.id}"]
	listener {
		instance_port = 80
		instance_protocol = "http"
		lb_port = 80
		lb_protocol = "http"
	}

	health_check {
		health_threshold = "${var.elb_healthy_threshold}"
		unhealthy_threshold = "${var.elb_unhealthy_threshold}"
		timeout = "${var.elb_timeout}"
		target = "HTTP:80/"
		interval = "${var.elb_interval}"
	}

	cross_zone_load_balancing	= true
	idle_timeout = 400
	connection_draining = true
	connection_draining_timeout = 400

	tags {
		Name = "${var.domain_name}-prod-elb"
	}
}

#AMI
#Launch
#ASG
#Route53
#Primary zone
#www
#dev
#db


# IAM
# S3 Access

resource "aws_iam_instance_profile" "s3_access" {
	name = "s3_access"
	role = "${aws_iam_role.s3_access.name}"
}

resource "aws_iam_role_policy" "s3_access_prolicy" {
	name = "s3_access_policy"
	role = "${aws_iam_role.s3_access.id}"
	policy = <<EOF
{
	"Version":	"2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Action": "s3:*",
			"Resource": "*"
		}
	]
}
EOF
}
resource "aws_iam_role" "s3_access" {
	name = "s3_access" 
	assume_role_policy = <<EOF
{
	"Version": "2012-10-17",
	"Statment": [
	{
		"Action": "sts:AssumeRole",
		"Principal": {
			"Service": "ec2.amazonaws.com"
		},
		"Effect": "Allow",
		"Sid": ""
		}
	]
}
EOF
}


