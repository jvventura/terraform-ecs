provider "aws" {
	version = "~> 2.7"
  	region  = var.aws_region
	profile = "default"
}

locals {
	name = "hello-world"
	environment = "dev"
}

# VPC - This sets up the cloud networking for the cluster.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 2.0"

  name = local.name

  cidr = "10.1.0.0/16"

  azs             = ["us-east-1f"]
  private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
  public_subnets  = ["10.1.11.0/24", "10.1.12.0/24"]

  enable_nat_gateway = true

  tags = {
    Environment = local.environment
    Name        = local.name
  }
}

# Cloudwatch - This creates a log group for the containers.

resource "aws_cloudwatch_log_group" "default" {
	name              = "${local.name}-${terraform.workspace}"
	retention_in_days = 1
}

# ECR - This sets up the remote image repo to deploy to (see README).

resource "aws_ecr_repository" "default" {
	name = "${local.name}-${terraform.workspace}"
}

data "template_file" "ecr-lifecycle" {
  	template = <<DEFINITION
	{
		"rules": [{
			"rulePriority": 1,
			"description": "Expire outdated tagged images",
			"selection": {
			"tagStatus": "any",
			"countType": "imageCountMoreThan",
			"countNumber": 1
			},
			"action": {
				"type": "expire"
			}
		}]
	}
	DEFINITION
}

resource "aws_ecr_lifecycle_policy" "this" {
	repository = aws_ecr_repository.default.name
	policy = data.template_file.ecr-lifecycle.rendered
}

# ECS IAM - This sets up the IAM roles for the containers.

resource "aws_iam_role" "tasks_execution" {
	name               = "${local.name}-${terraform.workspace}-task-execution-role"
	assume_role_policy = file("${path.module}/tf_policies/task_execution_role.json")
}

resource "aws_iam_policy" "tasks_execution" {
	name	= "${local.name}-${terraform.workspace}-task-execution-policy"
	policy 	= file("${path.module}/tf_policies/task_execution_role_policy.json")
}

resource "aws_iam_role_policy_attachment" "tasks_execution" {
	role       = aws_iam_role.tasks_execution.name
	policy_arn = aws_iam_policy.tasks_execution.arn
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
	role		= aws_iam_role.tasks_execution.name
	policy_arn	= "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

# data "template_file" "tasks_execution_ssm" {
#   count = var.ssm_allowed_parameters != "" ? 1 : 0

#   template = file("${path.module}/policies/ecs-task-execution-role-policy-ssm.json")

#   vars = {
#     ssm_parameters_arn = replace(var.ssm_allowed_parameters, "arn:aws:ssm", "") == var.ssm_allowed_parameters ? "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_allowed_parameters}" : var.ssm_allowed_parameters
#   }
# }

# resource "aws_iam_policy" "tasks_execution_ssm" {
#   count = var.ssm_allowed_parameters != "" ? 1 : 0

#   name = "${var.name}-${terraform.workspace}-task-execution-ssm-policy"

#   policy = data.template_file.tasks_execution_ssm[count.index].rendered
# }

# resource "aws_iam_role_policy_attachment" "tasks_execution_ssm" {
#   count = var.ssm_allowed_parameters != "" ? 1 : 0

#   role       = aws_iam_role.tasks_execution.name
#   policy_arn = aws_iam_policy.tasks_execution_ssm[count.index].arn
# }

# ECS - This sets up the cluster, service, and defines the task(s).

resource "aws_ecs_task_definition" "this" {
	family                   = "${local.name}-default"
	network_mode             = "awsvpc"
	requires_compatibilities = ["FARGATE"]
	cpu                      = var.fargate_cpu
	memory                   = var.fargate_memory
	execution_role_arn       = aws_iam_role.tasks_execution.arn

	container_definitions = <<DEFINITION
	[
		{
			"cpu": ${var.fargate_cpu},
			"image": "${aws_ecr_repository.default.repository_url}",
			"memory": ${var.fargate_memory},
			"name": "${local.name}-default",
			"networkMode": "awsvpc",
			"portMappings": [
				{
				"containerPort": ${var.app_port},
				"hostPort": ${var.app_port}
				}
			],
			"logConfiguration": {
				"logDriver": "awslogs",
				"options": {
					"awslogs-region": "us-east-1",
					"awslogs-group": "${local.name}-${terraform.workspace}",
					"awslogs-stream-prefix": "${local.name}"
				}
			},
			"awsvpcConfiguration": {
				"subnets": ${jsonencode(module.vpc.private_subnets)},
				"securityGroups": ${jsonencode(module.vpc.default_security_group_id)}
			}
		}
	]
	DEFINITION
}

resource "aws_ecs_cluster" "this" {
	name = "${local.name}-${terraform.workspace}-cluster"
}

resource "aws_ecs_service" "this" {
	name            = "main"
	cluster         = aws_ecs_cluster.this.id
	task_definition = aws_ecs_task_definition.this.arn
	desired_count   = var.app_count
	launch_type     = "FARGATE"

	network_configuration {
    	security_groups = [module.vpc.default_security_group_id]
    	subnets         = module.vpc.private_subnets
	}
}