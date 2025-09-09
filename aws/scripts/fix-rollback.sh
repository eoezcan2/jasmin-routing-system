#!/bin/bash

# Jasmin Routing System - Fix ROLLBACK_COMPLETE State
# This script helps resolve CloudFormation stack issues

set -e

# Configuration
ENVIRONMENT=${1:-production}
REGION=${2:-eu-central-1}
STACK_NAME="${ENVIRONMENT}-jasmin-stack"
NEW_STACK_NAME="${ENVIRONMENT}-jasmin-stack-$(date +%Y%m%d-%H%M%S)"

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

# Function to check stack status
check_stack_status() {
    print_status "Checking stack status..."
    
    if aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION &> /dev/null; then
        STACK_STATUS=$(aws cloudformation describe-stacks \
            --stack-name $STACK_NAME \
            --region $REGION \
            --query 'Stacks[0].StackStatus' \
            --output text)
        
        print_info "Current stack status: $STACK_STATUS"
        return 0
    else
        print_warning "Stack $STACK_NAME does not exist"
        return 1
    fi
}

# Function to show stack events
show_stack_events() {
    print_status "Showing recent stack events..."
    
    aws cloudformation describe-stack-events \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'StackEvents[0:10].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
        --output table
}

# Function to delete stack
delete_stack() {
    print_warning "This will delete the stack $STACK_NAME and all its resources!"
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Deleting stack $STACK_NAME..."
        
        aws cloudformation delete-stack \
            --stack-name $STACK_NAME \
            --region $REGION
        
        print_status "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete \
            --stack-name $STACK_NAME \
            --region $REGION
        
        print_status "Stack deleted successfully"
        return 0
    else
        print_info "Stack deletion cancelled"
        return 1
    fi
}

# Function to deploy with new stack name
deploy_new_stack() {
    print_status "Deploying new stack with name: $NEW_STACK_NAME"
    
    # Update the deploy script to use the new stack name
    sed -i.bak "s/STACK_NAME=\"${ENVIRONMENT}-jasmin-stack\"/STACK_NAME=\"$NEW_STACK_NAME\"/g" aws/scripts/deploy.sh
    
    print_info "Updated deploy.sh to use new stack name: $NEW_STACK_NAME"
    print_info "You can now run: ./aws/scripts/deploy.sh $ENVIRONMENT $REGION"
}

# Function to show cleanup options
show_cleanup_options() {
    print_status "Available cleanup options:"
    echo
    echo "1. Delete the current stack and recreate it"
    echo "2. Deploy with a new stack name (recommended)"
    echo "3. Show stack events to understand what failed"
    echo "4. Exit"
    echo
}

# Function to cleanup orphaned resources
cleanup_orphaned_resources() {
    print_status "Checking for orphaned resources..."
    
    # Check for orphaned ECR repositories
    if aws ecr describe-repositories --repository-names jasmin --region $REGION &> /dev/null; then
        print_warning "Found ECR repository 'jasmin'. Do you want to delete it? (y/N): "
        read -p "" -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            aws ecr delete-repository --repository-name jasmin --force --region $REGION
            print_status "ECR repository deleted"
        fi
    fi
    
    # Check for orphaned secrets
    for secret in "$ENVIRONMENT/redis" "$ENVIRONMENT/rabbitmq" "$ENVIRONMENT/jasmin"; do
        if aws secretsmanager describe-secret --secret-id "$secret" --region $REGION &> /dev/null; then
            print_warning "Found secret '$secret'. Do you want to delete it? (y/N): "
            read -p "" -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery --region $REGION
                print_status "Secret '$secret' deleted"
            fi
        fi
    done
    
    # Check for orphaned IAM roles
    for role in "$ENVIRONMENT-ecs-task-role" "$ENVIRONMENT-ecs-task-execution-role"; do
        if aws iam get-role --role-name "$role" &> /dev/null; then
            print_warning "Found IAM role '$role'. Do you want to delete it? (y/N): "
            read -p "" -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                # Detach policies first
                aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text | tr '\t' '\n' | while read policy; do
                    if [ ! -z "$policy" ]; then
                        aws iam detach-role-policy --role-name "$role" --policy-arn "$policy"
                    fi
                done
                aws iam delete-role --role-name "$role"
                print_status "IAM role '$role' deleted"
            fi
        fi
    done
}

# Main function
main() {
    print_status "Jasmin Routing System - Fix ROLLBACK_COMPLETE State"
    print_status "Environment: $ENVIRONMENT"
    print_status "Region: $REGION"
    print_status "Current Stack: $STACK_NAME"
    print_status "New Stack Name: $NEW_STACK_NAME"
    echo
    
    # Check prerequisites
    check_aws_cli
    
    # Check if stack exists and get status
    if check_stack_status; then
        show_stack_events
        echo
        
        while true; do
            show_cleanup_options
            read -p "Choose an option (1-4): " choice
            
            case $choice in
                1)
                    if delete_stack; then
                        print_status "Stack deleted. You can now run the deploy script again."
                        print_info "Run: ./aws/scripts/deploy.sh $ENVIRONMENT $REGION"
                    fi
                    break
                    ;;
                2)
                    deploy_new_stack
                    break
                    ;;
                3)
                    show_stack_events
                    echo
                    ;;
                4)
                    print_info "Exiting..."
                    exit 0
                    ;;
                *)
                    print_error "Invalid option. Please choose 1-4."
                    ;;
            esac
        done
    else
        print_info "No stack found. You can proceed with normal deployment."
        print_info "Run: ./aws/scripts/deploy.sh $ENVIRONMENT $REGION"
    fi
    
    # Offer to cleanup orphaned resources
    echo
    print_warning "Would you like to check for orphaned resources that might need cleanup? (y/N): "
    read -p "" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup_orphaned_resources
    fi
    
    print_status "Fix script completed!"
}

# Run main function
main "$@"

