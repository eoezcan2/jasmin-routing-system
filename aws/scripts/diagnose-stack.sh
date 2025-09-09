#!/bin/bash

# Jasmin Routing System - Stack Diagnosis Script
# This script helps diagnose CloudFormation stack issues

set -e

# Configuration
ENVIRONMENT=${1:-production}
REGION=${2:-eu-central-1}
STACK_NAME="${ENVIRONMENT}-jasmin-stack"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to check stack status
check_stack_status() {
    print_status "Checking stack status..."
    
    if aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION &> /dev/null; then
        STACK_STATUS=$(aws cloudformation describe-stacks \
            --stack-name $STACK_NAME \
            --region $REGION \
            --query 'Stacks[0].StackStatus' \
            --output text)
        
        print_info "Stack Status: $STACK_STATUS"
        return 0
    else
        print_error "Stack $STACK_NAME does not exist"
        return 1
    fi
}

# Function to show failed resources
show_failed_resources() {
    print_status "Showing failed resources..."
    
    aws cloudformation describe-stack-events \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'StackEvents[?ResourceStatus==`CREATE_FAILED` || ResourceStatus==`UPDATE_FAILED` || ResourceStatus==`DELETE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]' \
        --output table
}

# Function to show recent events
show_recent_events() {
    print_status "Showing recent stack events..."
    
    aws cloudformation describe-stack-events \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'StackEvents[0:20].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
        --output table
}

# Function to check resource dependencies
check_resource_dependencies() {
    print_status "Checking resource dependencies..."
    
    # Check if VPC exists
    VPC_ID=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`VPCId`].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    
    if [ "$VPC_ID" != "N/A" ] && [ "$VPC_ID" != "None" ]; then
        print_info "VPC ID: $VPC_ID"
        
        # Check VPC state
        VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION --query 'Vpcs[0].State' --output text 2>/dev/null || echo "N/A")
        print_info "VPC State: $VPC_STATE"
    else
        print_warning "VPC not found in stack outputs"
    fi
    
    # Check if subnets exist
    SUBNETS=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?contains(OutputKey, `Subnet`)].OutputValue' \
        --output text 2>/dev/null || echo "N/A")
    
    if [ "$SUBNETS" != "N/A" ] && [ "$SUBNETS" != "None" ]; then
        print_info "Subnets found: $(echo $SUBNETS | wc -w)"
        for subnet in $SUBNETS; do
            if [ "$subnet" != "None" ]; then
                SUBNET_STATE=$(aws ec2 describe-subnets --subnet-ids $subnet --region $REGION --query 'Subnets[0].State' --output text 2>/dev/null || echo "N/A")
                print_info "Subnet $subnet State: $SUBNET_STATE"
            fi
        done
    else
        print_warning "No subnets found in stack outputs"
    fi
}

# Function to check IAM roles
check_iam_roles() {
    print_status "Checking IAM roles..."
    
    for role in "$ENVIRONMENT-ecs-task-role" "$ENVIRONMENT-ecs-task-execution-role"; do
        if aws iam get-role --role-name "$role" &> /dev/null; then
            print_info "IAM Role '$role' exists"
            
            # Check attached policies
            POLICIES=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || echo "None")
            print_info "  Attached policies: $POLICIES"
        else
            print_warning "IAM Role '$role' does not exist"
        fi
    done
}

# Function to check secrets
check_secrets() {
    print_status "Checking AWS Secrets Manager secrets..."
    
    for secret in "$ENVIRONMENT/redis" "$ENVIRONMENT/rabbitmq" "$ENVIRONMENT/jasmin"; do
        if aws secretsmanager describe-secret --secret-id "$secret" --region $REGION &> /dev/null; then
            print_info "Secret '$secret' exists"
        else
            print_warning "Secret '$secret' does not exist"
        fi
    done
}

# Function to check ECR repository
check_ecr() {
    print_status "Checking ECR repository..."
    
    if aws ecr describe-repositories --repository-names jasmin --region $REGION &> /dev/null; then
        print_info "ECR repository 'jasmin' exists"
        
        # Check for images
        IMAGE_COUNT=$(aws ecr describe-images --repository-name jasmin --region $REGION --query 'length(imageDetails)' --output text 2>/dev/null || echo "0")
        print_info "  Number of images: $IMAGE_COUNT"
    else
        print_warning "ECR repository 'jasmin' does not exist"
    fi
}

# Function to check ECS resources
check_ecs() {
    print_status "Checking ECS resources..."
    
    # Check cluster
    CLUSTER_NAME="$ENVIRONMENT-jasmin-cluster"
    if aws ecs describe-clusters --clusters $CLUSTER_NAME --region $REGION &> /dev/null; then
        CLUSTER_STATUS=$(aws ecs describe-clusters --clusters $CLUSTER_NAME --region $REGION --query 'clusters[0].status' --output text)
        print_info "ECS Cluster '$CLUSTER_NAME' exists (Status: $CLUSTER_STATUS)"
    else
        print_warning "ECS Cluster '$CLUSTER_NAME' does not exist"
    fi
    
    # Check services
    if aws ecs list-services --cluster $CLUSTER_NAME --region $REGION &> /dev/null; then
        SERVICES=$(aws ecs list-services --cluster $CLUSTER_NAME --region $REGION --query 'serviceArns' --output text 2>/dev/null || echo "")
        if [ ! -z "$SERVICES" ]; then
            print_info "ECS Services found: $(echo $SERVICES | wc -w)"
            for service in $SERVICES; do
                SERVICE_NAME=$(echo $service | cut -d'/' -f3)
                SERVICE_STATUS=$(aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION --query 'services[0].status' --output text 2>/dev/null || echo "N/A")
                print_info "  Service '$SERVICE_NAME' (Status: $SERVICE_STATUS)"
            done
        else
            print_info "No ECS services found"
        fi
    fi
}

# Function to check load balancer
check_load_balancer() {
    print_status "Checking Application Load Balancer..."
    
    ALB_NAME="$ENVIRONMENT-jasmin-alb"
    if aws elbv2 describe-load-balancers --names $ALB_NAME --region $REGION &> /dev/null; then
        ALB_STATE=$(aws elbv2 describe-load-balancers --names $ALB_NAME --region $REGION --query 'LoadBalancers[0].State.Code' --output text)
        print_info "ALB '$ALB_NAME' exists (State: $ALB_STATE)"
    else
        print_warning "ALB '$ALB_NAME' does not exist"
    fi
}

# Function to provide recommendations
provide_recommendations() {
    print_status "Recommendations:"
    echo
    
    STACK_STATUS=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "N/A")
    
    case $STACK_STATUS in
        "ROLLBACK_COMPLETE")
            print_warning "Stack is in ROLLBACK_COMPLETE state. You have two options:"
            echo "  1. Delete the stack completely and recreate it"
            echo "  2. Deploy with a new stack name"
            echo
            print_info "Recommended: Use the fix-rollback.sh script"
            ;;
        "CREATE_FAILED")
            print_warning "Stack creation failed. Check the failed resources above."
            echo "  - Fix the issues identified"
            echo "  - Delete the stack and try again"
            ;;
        "UPDATE_ROLLBACK_COMPLETE")
            print_warning "Stack update failed and rolled back."
            echo "  - The stack is in a stable state"
            echo "  - You can try updating again"
            ;;
        "CREATE_COMPLETE")
            print_info "Stack creation completed successfully."
            ;;
        "UPDATE_COMPLETE")
            print_info "Stack update completed successfully."
            ;;
        *)
            print_warning "Unknown stack status: $STACK_STATUS"
            ;;
    esac
}

# Main function
main() {
    print_status "Jasmin Routing System - Stack Diagnosis"
    print_status "Environment: $ENVIRONMENT"
    print_status "Region: $REGION"
    print_status "Stack: $STACK_NAME"
    echo
    
    # Check if stack exists
    if ! check_stack_status; then
        exit 1
    fi
    
    echo
    print_status "=== DIAGNOSIS REPORT ==="
    echo
    
    # Show failed resources
    show_failed_resources
    echo
    
    # Show recent events
    show_recent_events
    echo
    
    # Check various resources
    check_resource_dependencies
    echo
    
    check_iam_roles
    echo
    
    check_secrets
    echo
    
    check_ecr
    echo
    
    check_ecs
    echo
    
    check_load_balancer
    echo
    
    # Provide recommendations
    provide_recommendations
    echo
    
    print_status "Diagnosis completed!"
}

# Run main function
main "$@"

