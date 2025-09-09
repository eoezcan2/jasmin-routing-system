#!/bin/bash

# Complete Jasmin Deployment - Create ECS Task Definition and Service

set -e

# Configuration
ENVIRONMENT=${1:-production}
REGION=${2:-eu-central-1}
STACK_NAME="production-jasmin-stack-20250829-211125"
ACCOUNT_ID="138264595889"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to get stack outputs
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
    TASK_EXECUTION_ROLE_ARN=$(echo $OUTPUTS | jq -r '.[] | select(.OutputKey=="ECSTaskExecutionRoleArn") | .OutputValue')
    
    # Get RabbitMQ endpoint
    RABBITMQ_ENDPOINT=$(aws mq describe-broker --broker-id "${ENVIRONMENT}-rabbitmq-${ACCOUNT_ID}-eu" --region $REGION --query "BrokerInstances[0].Endpoints[0]" --output text)
    
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
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$ENVIRONMENT-ecs-sg" \
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
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "$TASK_EXECUTION_ROLE_ARN",
  "taskRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/$ENVIRONMENT-ecs-task-role",
  "containerDefinitions": [
    {
      "name": "redis",
      "image": "redis:6-alpine",
      "cpu": 256,
      "memory": 512,
      "portMappings": [
        {
          "containerPort": 6379,
          "protocol": "tcp"
        }
      ],
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/$ENVIRONMENT-jasmin",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "redis"
        }
      }
    },
    {
      "name": "rabbitmq",
      "image": "rabbitmq:3-management-alpine",
      "cpu": 256,
      "memory": 512,
      "portMappings": [
        {
          "containerPort": 5672,
          "protocol": "tcp"
        },
        {
          "containerPort": 15672,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "RABBITMQ_DEFAULT_USER",
          "value": "admin"
        },
        {
          "name": "RABBITMQ_DEFAULT_PASS",
          "value": "test123"
        }
      ],
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/$ENVIRONMENT-jasmin",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "rabbitmq"
        }
      }
    },
    {
      "name": "jasmin",
      "image": "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/jasmin:latest",
      "cpu": 512,
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
          "value": "redis"
        },
        {
          "name": "REDIS_PORT",
          "value": "6379"
        },
        {
          "name": "RABBITMQ_HOST",
          "value": "rabbitmq"
        },
        {
          "name": "RABBITMQ_PORT",
          "value": "5672"
        },
        {
          "name": "RABBITMQ_USE_SSL",
          "value": "false"
        },
        {
          "name": "REDIS_PASSWORD",
          "value": "test123"
        },
        {
          "name": "RABBITMQ_USERNAME",
          "value": "admin"
        },
        {
          "name": "RABBITMQ_PASSWORD",
          "value": "test123"
        },
        {
          "name": "API_KEY",
          "value": "test123"
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
          "ps aux | grep jasmind || exit 1"
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

# Main function
main() {
    print_status "Completing Jasmin deployment..."
    print_status "Environment: $ENVIRONMENT"
    print_status "Region: $REGION"
    print_status "Stack: $STACK_NAME"
    echo
    
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
