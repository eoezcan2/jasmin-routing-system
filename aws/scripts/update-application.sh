#!/bin/bash

# Jasmin Routing System - Application Update Script
# This script updates only the application without redeploying infrastructure

set -e

# Configuration
ENVIRONMENT=${1:-production}
REGION=${2:-eu-central-1}
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

# Function to build and push new Docker image
build_and_push_image() {
    print_status "Building and pushing new Docker image..."
    
    # Get ECR login token
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com
    
    # Build image with timestamp tag
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    IMAGE_TAG="v${TIMESTAMP}"
    
    # Build image
    docker build -t $ECR_REPOSITORY_NAME:$IMAGE_TAG .
    docker tag $ECR_REPOSITORY_NAME:$IMAGE_TAG $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY_NAME:$IMAGE_TAG
    docker tag $ECR_REPOSITORY_NAME:$IMAGE_TAG $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY_NAME:latest
    
    # Push images
    docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY_NAME:$IMAGE_TAG
    docker push $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY_NAME:latest
    
    print_status "Docker image pushed successfully with tag: $IMAGE_TAG"
    echo $IMAGE_TAG
}

# Function to update ECS task definition
update_task_definition() {
    local IMAGE_TAG=$1
    
    print_status "Updating ECS task definition..."
    
    # Get current task definition
    CURRENT_TASK_DEF=$(aws ecs describe-task-definition --task-definition jasmin --region $REGION --query 'taskDefinition' --output json)
    
    # Update image in task definition
    UPDATED_TASK_DEF=$(echo $CURRENT_TASK_DEF | jq --arg IMAGE "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPOSITORY_NAME:$IMAGE_TAG" '.containerDefinitions[0].image = $IMAGE')
    
    # Remove fields that can't be updated
    UPDATED_TASK_DEF=$(echo $UPDATED_TASK_DEF | jq 'del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)')
    
    # Create temporary file
    echo $UPDATED_TASK_DEF > /tmp/updated-task-definition.json
    
    # Register new task definition
    NEW_TASK_DEF_ARN=$(aws ecs register-task-definition --cli-input-json file:///tmp/updated-task-definition.json --region $REGION --query 'taskDefinition.taskDefinitionArn' --output text)
    
    # Clean up
    rm -f /tmp/updated-task-definition.json
    
    print_status "New task definition registered: $NEW_TASK_DEF_ARN"
    echo $NEW_TASK_DEF_ARN
}

# Function to update ECS service
update_ecs_service() {
    local NEW_TASK_DEF_ARN=$1
    
    print_status "Updating ECS service..."
    
    # Update service with new task definition
    aws ecs update-service \
        --cluster "${ENVIRONMENT}-jasmin-cluster" \
        --service jasmin-service \
        --task-definition $NEW_TASK_DEF_ARN \
        --region $REGION
    
    print_status "ECS service updated successfully"
}

# Function to wait for deployment to complete
wait_for_deployment() {
    print_status "Waiting for deployment to complete..."
    
    # Wait for service to be stable
    aws ecs wait services-stable \
        --cluster "${ENVIRONMENT}-jasmin-cluster" \
        --services jasmin-service \
        --region $REGION
    
    print_status "Deployment completed successfully!"
}

# Function to check service health
check_service_health() {
    print_status "Checking service health..."
    
    # Get service details
    SERVICE_DETAILS=$(aws ecs describe-services \
        --cluster "${ENVIRONMENT}-jasmin-cluster" \
        --services jasmin-service \
        --region $REGION)
    
    # Check running count
    RUNNING_COUNT=$(echo $SERVICE_DETAILS | jq -r '.services[0].runningCount')
    DESIRED_COUNT=$(echo $SERVICE_DETAILS | jq -r '.services[0].desiredCount')
    
    if [ "$RUNNING_COUNT" -eq "$DESIRED_COUNT" ]; then
        print_status "Service is healthy: $RUNNING_COUNT/$DESIRED_COUNT tasks running"
    else
        print_error "Service is unhealthy: $RUNNING_COUNT/$DESIRED_COUNT tasks running"
        exit 1
    fi
    
    # Check target group health
    ALB_DNS=$(aws cloudformation describe-stacks \
        --stack-name "${ENVIRONMENT}-jasmin-stack" \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
        --output text)
    
    print_status "Testing HTTP API health check..."
    if curl -f "http://$ALB_DNS:1401/ping" &> /dev/null; then
        print_status "HTTP API is responding"
    else
        print_warning "HTTP API health check failed"
    fi
}

# Function to rollback if needed
rollback() {
    local PREVIOUS_TASK_DEF_ARN=$1
    
    print_warning "Rolling back to previous task definition..."
    
    # Update service to previous task definition
    aws ecs update-service \
        --cluster "${ENVIRONMENT}-jasmin-cluster" \
        --service jasmin-service \
        --task-definition $PREVIOUS_TASK_DEF_ARN \
        --region $REGION
    
    # Wait for rollback to complete
    aws ecs wait services-stable \
        --cluster "${ENVIRONMENT}-jasmin-cluster" \
        --services jasmin-service \
        --region $REGION
    
    print_status "Rollback completed"
}

# Function to cleanup old images
cleanup_old_images() {
    print_status "Cleaning up old Docker images..."
    
    # Keep only the last 5 images
    IMAGES=$(aws ecr list-images \
        --repository-name $ECR_REPOSITORY_NAME \
        --region $REGION \
        --query 'imageIds[?imageTag!=`latest`]' \
        --output json)
    
    IMAGE_COUNT=$(echo $IMAGES | jq length)
    
    if [ $IMAGE_COUNT -gt 5 ]; then
        # Get images sorted by creation date (oldest first)
        OLD_IMAGES=$(aws ecr describe-images \
            --repository-name $ECR_REPOSITORY_NAME \
            --region $REGION \
            --query 'imageDetails[?imageTags[0]!=`latest`] | sort_by(@, &imagePushedAt) | [0:5] | [].imageTags[0]' \
            --output json)
        
        # Delete old images
        for IMAGE_TAG in $(echo $OLD_IMAGES | jq -r '.[]'); do
            if [ ! -z "$IMAGE_TAG" ] && [ "$IMAGE_TAG" != "null" ]; then
                print_status "Deleting old image: $IMAGE_TAG"
                aws ecr batch-delete-image \
                    --repository-name $ECR_REPOSITORY_NAME \
                    --image-ids imageTag=$IMAGE_TAG \
                    --region $REGION || true
            fi
        done
    fi
    
    print_status "Image cleanup completed"
}

# Main update function
main() {
    print_status "Starting application update for environment: $ENVIRONMENT in region: $REGION"
    
    # Check prerequisites
    check_aws_cli
    
    # Get account ID
    ACCOUNT_ID=$(get_account_id)
    print_status "AWS Account ID: $ACCOUNT_ID"
    
    # Get current task definition ARN for rollback
    CURRENT_TASK_DEF_ARN=$(aws ecs describe-services \
        --cluster "${ENVIRONMENT}-jasmin-cluster" \
        --services jasmin-service \
        --region $REGION \
        --query 'services[0].taskDefinition' \
        --output text)
    
    print_status "Current task definition: $CURRENT_TASK_DEF_ARN"
    
    # Build and push new image
    NEW_IMAGE_TAG=$(build_and_push_image)
    
    # Update task definition
    NEW_TASK_DEF_ARN=$(update_task_definition $NEW_IMAGE_TAG)
    
    # Update ECS service
    update_ecs_service $NEW_TASK_DEF_ARN
    
    # Wait for deployment
    wait_for_deployment
    
    # Check service health
    if check_service_health; then
        print_status "Application update completed successfully!"
        
        # Cleanup old images
        cleanup_old_images
        
        # Get ALB DNS
        ALB_DNS=$(aws cloudformation describe-stacks \
            --stack-name "${ENVIRONMENT}-jasmin-stack" \
            --region $REGION \
            --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
            --output text)
        
        print_status "Application is available at:"
        print_status "  SMPP: $ALB_DNS:2775"
        print_status "  HTTP API: $ALB_DNS:1401"
        print_status "  CLI: $ALB_DNS:8990"
    else
        print_error "Application update failed. Rolling back..."
        rollback $CURRENT_TASK_DEF_ARN
        exit 1
    fi
}

# Run main function
main "$@"
