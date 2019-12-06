## Startup

Build the image:
`npm run docker-build`

Push the image to the ECR (you will need to authenticate your accounts first, see below):
`npm run push-ecr`

Run terraform:
```
terraform init
terraform plan
terraform apply
```

## Authenticating with AWS and Docker

Login with AWS:
`aws configure`

Login with Docker:
`docker login --username <username> --password <password>`

Authenticate AWS with Docker:
`aws ecr get-login --region us-east-1 --no-include-email`
The output of the above command is a command to authenticate. Simply copy, paste, and run.

## Executing task

The task will be setup to be triggered by defined Cloudwatch event rule pattern in `tf_templates`.

To execute the task, setup a `aws events put-event` call.