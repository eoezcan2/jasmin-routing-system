#!/bin/bash

# Jasmin Routing System AWS Cleanup Script
# This script removes all AWS resources created for the deployment

set -e

# Configuration
ENVIRONMENT=${1:-production}
REGION=${2:-eu-central-1}
STACK_NAME="${ENVIRONMENT}-jasmin-stack"
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

# Function to delete ECS service
delete_ecs_service() {
    print_status "Deleting ECS service..."
    
    if aws ecs describe-services --cluster "${ENVIRONMENT}-jasmin-cluster" --services jasmin-service --region $REGION &> /dev/null; then
        # Scale down to 0 first
        aws ecs update-service \
            --cluster "${ENVIRONMENT}-jasmin-cluster" \
            --service jasmin-service \
            --desired-count 0 \
            --region $REGION
        
        # Wait for tasks to stop
        print_status "Waiting for ECS tasks to stop..."
        aws ecs wait services-stable \
            --cluster "${ENVIRONMENT}-jasmin-cluster" \
            --services jasmin-service \
            --region $REGION
        
        # Delete service
        aws ecs delete-service \
            --cluster "${ENVIRONMENT}-jasmin-cluster" \
            --service jasmin-service \
            --region $REGION
        
        print_status "ECS service deleted successfully"
    else
        print_status "ECS service does not exist"
    fi
}

# Function to delete ECS task definitions
delete_ecs_task_definitions() {
    print_status "Deleting ECS task definitions..."
    
    # Get all task definition revisions
    TASK_DEFINITIONS=$(aws ecs list-task-definitions --family-prefix jasmin --region $REGION --query 'taskDefinitionArns' --output text)
    
    if [ ! -z "$TASK_DEFINITIONS" ]; then
        for TASK_DEF in $TASK_DEFINITIONS; do
            print_status "Deregistering task definition: $TASK_DEF"
            aws ecs deregister-task-definition --task-definition $TASK_DEF --region $REGION
        done
        print_status "All task definitions deleted successfully"
    else
        print_status "No task definitions found"
    fi
}

# Function to delete ECS cluster
delete_ecs_cluster() {
    print_status "Deleting ECS cluster..."
    
    if aws ecs describe-clusters --clusters "${ENVIRONMENT}-jasmin-cluster" --region $REGION &> /dev/null; then
        aws ecs delete-cluster --cluster "${ENVIRONMENT}-jasmin-cluster" --region $REGION
        print_status "ECS cluster deleted successfully"
    else
        print_status "ECS cluster does not exist"
    fi
}

# Function to delete ECR repository
delete_ecr_repository() {
    print_status "Deleting ECR repository..."
    
    if aws ecr describe-repositories --repository-names $ECR_REPOSITORY_NAME --region $REGION &> /dev/null; then
        # Delete all images first
        IMAGES=$(aws ecr list-images --repository-name $ECR_REPOSITORY_NAME --region $REGION --query 'imageIds[*]' --output json)
        
        if [ "$IMAGES" != "[]" ]; then
            aws ecr batch-delete-image \
                --repository-name $ECR_REPOSITORY_NAME \
                --image-ids "$IMAGES" \
                --region $REGION
        fi
        
        # Delete repository
        aws ecr delete-repository --repository-name $ECR_REPOSITORY_NAME --region $REGION
        print_status "ECR repository deleted successfully"
    else
        print_status "ECR repository does not exist"
    fi
}

# Function to delete IAM roles
delete_iam_roles() {
    print_status "Deleting IAM roles..."
    
    # Delete task role
    if aws iam get-role --role-name "${ENVIRONMENT}-ecs-task-role" &> /dev/null; then
        # Detach policies first
        aws iam detach-role-policy --role-name "${ENVIRONMENT}-ecs-task-role" --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess || true
        aws iam detach-role-policy --role-name "${ENVIRONMENT}-ecs-task-role" --policy-arn arn:aws:iam::aws:policy/AmazonElastiCacheFullAccess || true
        aws iam detach-role-policy --role-name "${ENVIRONMENT}-ecs-task-role" --policy-arn arn:aws:iam::aws:policy/AmazonMQFullAccess || true
        
        # Delete role
        aws iam delete-role --role-name "${ENVIRONMENT}-ecs-task-role"
        print_status "ECS task role deleted successfully"
    else
        print_status "ECS task role does not exist"
    fi
}

# Function to delete CloudWatch log group
delete_cloudwatch_log_group() {
    print_status "Deleting CloudWatch log group..."
    
    if aws logs describe-log-groups --log-group-name-prefix "/ecs/${ENVIRONMENT}-jasmin" --region $REGION &> /dev/null; then
        aws logs delete-log-group --log-group-name "/ecs/${ENVIRONMENT}-jasmin" --region $REGION
        print_status "CloudWatch log group deleted successfully"
    else
        print_status "CloudWatch log group does not exist"
    fi
}

# Function to delete AWS Secrets Manager secrets
delete_secrets() {
    print_status "Deleting AWS Secrets Manager secrets..."
    
    # Delete Redis secret
    if aws secretsmanager describe-secret --secret-id "$ENVIRONMENT/redis" --region $REGION &> /dev/null; then
        aws secretsmanager delete-secret --secret-id "$ENVIRONMENT/redis" --force-delete-without-recovery --region $REGION
        print_status "Redis secret deleted"
    else
        print_status "Redis secret does not exist"
    fi
    
    # Delete RabbitMQ secret
    if aws secretsmanager describe-secret --secret-id "$ENVIRONMENT/rabbitmq" --region $REGION &> /dev/null; then
        aws secretsmanager delete-secret --secret-id "$ENVIRONMENT/rabbitmq" --force-delete-without-recovery --region $REGION
        print_status "RabbitMQ secret deleted"
    else
        print_status "RabbitMQ secret does not exist"
    fi
    
    # Delete Jasmin secret
    if aws secretsmanager describe-secret --secret-id "$ENVIRONMENT/jasmin" --region $REGION &> /dev/null; then
        aws secretsmanager delete-secret --secret-id "$ENVIRONMENT/jasmin" --force-delete-without-recovery --region $REGION
        print_status "Jasmin secret deleted"
    else
        print_status "Jasmin secret does not exist"
    fi
}

# Function to delete CloudFormation stack
delete_cloudformation_stack() {
    print_status "Deleting CloudFormation stack..."
    
    if aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION &> /dev/null; then
        aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
        
        print_status "Waiting for CloudFormation stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
        
        print_status "CloudFormation stack deleted successfully"
    else
        print_status "CloudFormation stack does not exist"
    fi
}

# Function to confirm deletion
confirm_deletion() {
    print_warning "This will delete ALL AWS resources for the $ENVIRONMENT environment!"
    print_warning "This includes:"
    print_warning "  - ECS cluster, service, and task definitions"
    print_warning "  - ECR repository and Docker images"
    print_warning "  - Application Load Balancer and target groups"
    print_warning "  - ElastiCache Redis cluster"
    print_warning "  - Amazon MQ RabbitMQ broker"
    print_warning "  - VPC, subnets, and security groups"
    print_warning "  - IAM roles and policies"
    print_warning "  - CloudWatch log groups"
    print_warning "  - AWS Secrets Manager secrets"
    print_warning "  - CloudFormation stack"
    echo
    read -p "Are you sure you want to continue? (yes/no): " -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "Deletion cancelled"
        exit 0
    fi
}

# Main cleanup function
main() {
    print_status "Starting cleanup for environment: $ENVIRONMENT in region: $REGION"
    
    # Check prerequisites
    check_aws_cli
    
    # Confirm deletion
    confirm_deletion
    
    # Get account ID
    ACCOUNT_ID=$(get_account_id)
    print_status "AWS Account ID: $ACCOUNT_ID"
    
    # Delete resources in reverse order of dependencies
    
    # 1. Delete ECS service first
    delete_ecs_service
    
    # 2. Delete ECS task definitions
    delete_ecs_task_definitions
    
    # 3. Delete ECS cluster
    delete_ecs_cluster
    
    # 4. Delete ECR repository
    delete_ecr_repository
    
    # 5. Delete IAM roles
    delete_iam_roles
    
    # 6. Delete CloudWatch log group
    delete_cloudwatch_log_group
    
    # 7. Delete AWS Secrets Manager secrets
    delete_secrets
    
    # 8. Delete CloudFormation stack (this will delete all infrastructure)
    delete_cloudformation_stack
    
    print_status "Cleanup completed successfully!"
    print_status "All AWS resources for the $ENVIRONMENT environment have been removed."
}

# Run main function
main "$@"
