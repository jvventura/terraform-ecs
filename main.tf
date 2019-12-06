provider "aws" {
	version = "~> 2.7"
  	region  = var.aws_region
	profile = "default"
}

locals {
	name = "hello-world"
	environment = var.environment
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
  	template = file("${path.module}/tf_templates/ecr_lifecycle.json")
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
			"image": "${aws_ecr_repository.default.repository_url}",
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
			}
		}
	]
	DEFINITION
}

resource "aws_ecs_cluster" "this" {
	name = "${local.name}-${terraform.workspace}-cluster"
}

# We don't need a service, this runs constantly.
# resource "aws_ecs_service" "this" {
# 	name            = "main"
# 	cluster         = aws_ecs_cluster.this.id
# 	task_definition = aws_ecs_task_definition.this.arn
# 	desired_count   = var.app_count
# 	launch_type     = "FARGATE"

# 	network_configuration {
#     	security_groups = [module.vpc.default_security_group_id]
#     	subnets         = module.vpc.private_subnets
# 	}
# }

## Cloudwatch event

resource "aws_cloudwatch_event_rule" "triggered_task" {
	name		= "${local.name}_${local.environment}_triggered_task"
	description	= "Run ${local.name}_${local.environment} task on triggered event."
	event_pattern = jsonencode(jsondecode(file("${path.module}/tf_templates/cloudwatch_event_rule_patterns.json"))[0])
}

resource "aws_cloudwatch_event_target" "triggered_task" {
	target_id = "${local.name}_${local.environment}_triggered_task_target"
	rule      = aws_cloudwatch_event_rule.triggered_task.name
	arn       = aws_ecs_cluster.this.id
	role_arn  = aws_iam_role.tasks_execution.arn

	ecs_target {
		task_count          = var.app_count
		task_definition_arn = aws_ecs_task_definition.this.arn
		launch_type         = "FARGATE"
		platform_version    = "LATEST"

		network_configuration {
			security_groups = [module.vpc.default_security_group_id]
			subnets         = module.vpc.private_subnets
		}
	}
}