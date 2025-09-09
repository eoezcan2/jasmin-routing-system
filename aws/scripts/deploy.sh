#!/bin/bash

# Jasmin Routing System AWS Deployment Script
# This script deploys the complete infrastructure and application to AWS

set -e

# Configuration
ENVIRONMENT=${1:-production}
REGION=${2:-eu-central-1}
STACK_NAME="production-jasmin-stack-20250829-211125"
ECR_REPOSITORY_NAME="jasmin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if AWS CLI is installed and configured
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI is not configured. Please run 'aws configure' first."
        exit 1
    fi
    
    print_status "AWS CLI is configured and ready"
}

# Function to get AWS account ID
get_account_id() {
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo $ACCOUNT_ID
}

# Function to create ECR repository
create_ecr_repository() {
    print_status "Creating ECR repository..."
    
    if ! aws ecr describe-repositories --repository-names $ECR_REPOSITORY_NAME --region $REGION &> /dev/null; then
        aws ecr create-repository \
            --repository-name $ECR_REPOSITORY_NAME \
            --region $REGION \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256
        print_status "ECR repository created successfully"
    else
        print_status "ECR repository already exists"
    fi
}

# Function to build and push Docker image
build_and_push_image() {
    print_status "Building and pushing Docker image..."
    
    # Get ECR login token
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
    
    # Build image
    docker build -t $ECR_REPOSITORY_NAME .
    
    # Tag image
    docker tag $ECR_REPOSITORY_NAME:latest $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY_NAME:latest
    
    # Push image
    docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY_NAME:latest
    
    print_status "Docker image pushed successfully"
}

# Function to create AWS Secrets Manager secrets
create_secrets() {
    print_status "Creating AWS Secrets Manager secrets..."
    
    # Redis password
    if ! aws secretsmanager describe-secret --secret-id "$ENVIRONMENT/redis" --region $REGION &> /dev/null; then
        aws secretsmanager create-secret \
            --name "$ENVIRONMENT/redis" \
            --description "Redis password for $ENVIRONMENT environment" \
            --secret-string '{"password":"'$(openssl rand -base64 32)'"}' \
            --region $REGION
        print_status "Redis secret created"
    else
        print_status "Redis secret already exists"
    fi
    
    # RabbitMQ credentials
    if ! aws secretsmanager describe-secret --secret-id "$ENVIRONMENT/rabbitmq" --region $REGION &> /dev/null; then
        # Generate password without invalid characters for RabbitMQ
        RABBITMQ_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
        aws secretsmanager create-secret \
            --name "$ENVIRONMENT/rabbitmq" \
            --description "RabbitMQ credentials for $ENVIRONMENT environment" \
            --secret-string "{\"username\":\"admin\",\"password\":\"$RABBITMQ_PASSWORD\"}" \
            --region $REGION
        print_status "RabbitMQ secret created"
    else
        print_status "RabbitMQ secret already exists"
    fi
    
    # Jasmin API key
    if ! aws secretsmanager describe-secret --secret-id "$ENVIRONMENT/jasmin" --region $REGION &> /dev/null; then
        aws secretsmanager create-secret \
            --name "$ENVIRONMENT/jasmin" \
            --description "Jasmin API key for $ENVIRONMENT environment" \
            --secret-string '{"api_key":"'$(openssl rand -base64 32)'"}' \
            --region $REGION
        print_status "Jasmin API key secret created"
    else
        print_status "Jasmin API key secret already exists"
    fi
}

# Function to deploy CloudFormation stack
deploy_infrastructure() {
    print_status "Deploying infrastructure with CloudFormation..."
    
    aws cloudformation deploy \
        --template-file aws/cloudformation/infrastructure.yml \
        --stack-name $STACK_NAME \
        --parameter-overrides Environment=$ENVIRONMENT \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION
    
    print_status "Infrastructure deployed successfully"
}

# Function to get CloudFormation outputs
get_stack_outputs() {
    print_status "Getting stack outputs..."
    
    # Get all outputs
    OUTPUTS=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs' \
        --output json)
    
    # Extract specific values
    VPC_ID=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="VPCId") | .OutputValue')
    PRIVATE_SUBNET_1_ID=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="PrivateSubnet1Id") | .OutputValue')
    PRIVATE_SUBNET_2_ID=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="PrivateSubnet2Id") | .OutputValue')
    ECS_CLUSTER_NAME=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="ECSClusterName") | .OutputValue')
    ALB_ARN=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="ALBArn") | .OutputValue')
    REDIS_ENDPOINT=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="RedisEndpoint") | .OutputValue')
    RABBITMQ_ENDPOINT=$(aws mq describe-broker --broker-id "${ENVIRONMENT}-rabbitmq-${ACCOUNT_ID}-eu" --region $REGION --query "BrokerInstances[0].Endpoints[0]" --output text)
    TASK_EXECUTION_ROLE_ARN=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="ECSTaskExecutionRoleArn") | .OutputValue')
    
    # Get target group ARNs
    SMPP_TG_ARN=$(aws elbv2 describe-target-groups \
        --names "$ENVIRONMENT-smpp-tg" \
        --region $REGION \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    HTTP_TG_ARN=$(aws elbv2 describe-target-groups \
        --names "$ENVIRONMENT-http-tg" \
        --region $REGION \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    CLI_TG_ARN=$(aws elbv2 describe-target-groups \
        --names "$ENVIRONMENT-cli-tg" \
        --region $REGION \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    # Get ECS security group ID
    ECS_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$ENVIRONMENT-ecs-sg" \
        --region $REGION \
        --query 'SecurityGroups[0].GroupId' \
        --output text)
    
    print_status "Stack outputs retrieved successfully"
}

# Function to create ECS task role
create_ecs_task_role() {
    print_status "Creating ECS task role..."
    
    # Create trust policy
    cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    
    # Create role
    if ! aws iam get-role --role-name "$ENVIRONMENT-ecs-task-role" &> /dev/null; then
        aws iam create-role \
            --role-name "$ENVIRONMENT-ecs-task-role" \
            --assume-role-policy-document file:///tmp/trust-policy.json
        
        # Attach policies
        aws iam attach-role-policy \
            --role-name "$ENVIRONMENT-ecs-task-role" \
            --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
        
        aws iam attach-role-policy \
            --role-name "$ENVIRONMENT-ecs-task-role" \
            --policy-arn arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess
        
        aws iam attach-role-policy \
            --role-name "$ENVIRONMENT-ecs-task-role" \
            --policy-arn arn:aws:iam::aws:policy/AmazonMQFullAccess
        
        print_status "ECS task role created successfully"
    else
        print_status "ECS task role already exists"
    fi
    
    # Clean up
    rm -f /tmp/trust-policy.json
}

# Function to update task definition
update_task_definition() {
    print_status "Updating task definition..."
    
    # Create temporary task definition file
    cat > /tmp/task-definition.json << EOF
{
  "family": "jasmin",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "$TASK_EXECUTION_ROLE_ARN",
  "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/$ENVIRONMENT-ecs-task-role",
  "containerDefinitions": [
    {
      "name": "jasmin",
      "image": "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY_NAME:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 2775,
          "protocol": "tcp"
        },
        {
          "containerPort": 1401,
          "protocol": "tcp"
        },
        {
          "containerPort": 8990,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "JASMIN_INTERFACES",
          "value": "sm-http"
        },
        {
          "name": "REDIS_HOST",
          "value": "$REDIS_ENDPOINT"
        },
        {
          "name": "REDIS_PORT",
          "value": "6379"
        },
        {
          "name": "RABBITMQ_HOST",
          "value": "$RABBITMQ_ENDPOINT"
        },
        {
          "name": "RABBITMQ_PORT",
          "value": "5671"
        },
        {
          "name": "RABBITMQ_USE_SSL",
          "value": "true"
        }
      ],
      "secrets": [
        {
          "name": "REDIS_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:$ENVIRONMENT/redis:SecretString:password"
        },
        {
          "name": "RABBITMQ_USERNAME",
          "valueFrom": "arn:aws:secretsmanager:$ENVIRONMENT/rabbitmq:SecretString:username"
        },
        {
          "name": "RABBITMQ_PASSWORD",
          "valueFrom": "arn:aws:secretsmanager:$ENVIRONMENT/rabbitmq:SecretString:password"
        },
        {
          "name": "API_KEY",
          "valueFrom": "arn:aws:secretsmanager:$ENVIRONMENT/jasmin:SecretString:api_key"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/$ENVIRONMENT-jasmin",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:1401/ping || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
EOF
    
    # Register task definition
    aws ecs register-task-definition --cli-input-json file:///tmp/task-definition.json --region $REGION
    
    # Clean up
    rm -f /tmp/task-definition.json
    
    print_status "Task definition updated successfully"
}

# Function to create ECS service
create_ecs_service() {
    print_status "Creating ECS service..."
    
    # Create temporary service definition file
    cat > /tmp/service-definition.json << EOF
{
  "cluster": "$ECS_CLUSTER_NAME",
  "serviceName": "jasmin-service",
  "taskDefinition": "jasmin",
  "loadBalancers": [
    {
      "targetGroupArn": "$SMPP_TG_ARN",
      "containerName": "jasmin",
      "containerPort": 2775
    },
    {
      "targetGroupArn": "$HTTP_TG_ARN",
      "containerName": "jasmin",
      "containerPort": 1401
    },
    {
      "targetGroupArn": "$CLI_TG_ARN",
      "containerName": "jasmin",
      "containerPort": 8990
    }
  ],
  "desiredCount": 2,
  "launchType": "FARGATE",
  "platformVersion": "LATEST",
  "networkConfiguration": {
    "awsvpcConfiguration": {
      "subnets": [
        "$PRIVATE_SUBNET_1_ID",
        "$PRIVATE_SUBNET_2_ID"
      ],
      "securityGroups": [
        "$ECS_SG_ID"
      ],
      "assignPublicIp": "DISABLED"
    }
  },
  "deploymentConfiguration": {
    "maximumPercent": 200,
    "minimumHealthyPercent": 50,
    "deploymentCircuitBreaker": {
      "enable": true,
      "rollback": true
    }
  },
  "healthCheckGracePeriodSeconds": 60,
  "schedulingStrategy": "REPLICA",
  "enableECSManagedTags": true,
  "propagateTags": "SERVICE"
}
EOF
    
    # Create service
    aws ecs create-service --cli-input-json file:///tmp/service-definition.json --region $REGION
    
    # Clean up
    rm -f /tmp/service-definition.json
    
    print_status "ECS service created successfully"
}

# Function to get ALB DNS name
get_alb_dns() {
    ALB_DNS=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
        --output text)
    
    print_status "Application Load Balancer DNS: $ALB_DNS"
    print_status "SMPP Endpoint: $ALB_DNS:2775"
    print_status "HTTP API Endpoint: $ALB_DNS:1401"
    print_status "CLI Endpoint: $ALB_DNS:8990"
}

# Main deployment function
main() {
    print_status "Starting deployment for environment: $ENVIRONMENT in region: $REGION"
    
    # Check prerequisites
    check_aws_cli
    
    # Get account ID
    ACCOUNT_ID=$(get_account_id)
    print_status "AWS Account ID: $ACCOUNT_ID"
    
    # Create secrets
    create_secrets
    
    # Create ECR repository and push image
    create_ecr_repository
    build_and_push_image
    
    # Deploy infrastructure
    deploy_infrastructure
    
    # Get stack outputs
    get_stack_outputs
    
    # Create ECS task role
    create_ecs_task_role
    
    # Update task definition
    update_task_definition
    
    # Create ECS service
    create_ecs_service
    
    # Get ALB DNS
    get_alb_dns
    
    print_status "Deployment completed successfully!"
    print_status "Your Jasmin application is now running on AWS ECS with external Redis and RabbitMQ services."
}

# Run main function
main "$@"
