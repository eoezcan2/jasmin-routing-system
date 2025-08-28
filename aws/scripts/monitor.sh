#!/bin/bash

# Jasmin Routing System - Monitoring Script
# This script monitors the health and status of the deployed application

set -e

# Configuration
ENVIRONMENT=${1:-production}
REGION=${2:-eu-central-1}

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

print_header() {
    echo -e "${BLUE}[HEADER]${NC} $1"
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

# Function to get ALB DNS name
get_alb_dns() {
    ALB_DNS=$(aws cloudformation describe-stacks \
        --stack-name "${ENVIRONMENT}-jasmin-stack" \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`ALBDNSName`].OutputValue' \
        --output text)
    
    if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" == "None" ]; then
        print_error "Could not retrieve ALB DNS name"
        return 1
    fi
    
    echo $ALB_DNS
}

# Function to check ECS service status
check_ecs_service() {
    print_header "ECS Service Status"
    
    SERVICE_DETAILS=$(aws ecs describe-services \
        --cluster "${ENVIRONMENT}-jasmin-cluster" \
        --services jasmin-service \
        --region $REGION)
    
    # Check if service exists
    if [ $(echo $SERVICE_DETAILS | jq -r '.services | length') -eq 0 ]; then
        print_error "ECS service 'jasmin-service' not found"
        return 1
    fi
    
    SERVICE=$(echo $SERVICE_DETAILS | jq -r '.services[0]')
    
    # Service status
    STATUS=$(echo $SERVICE | jq -r '.status')
    DESIRED_COUNT=$(echo $SERVICE | jq -r '.desiredCount')
    RUNNING_COUNT=$(echo $SERVICE | jq -r '.runningCount')
    PENDING_COUNT=$(echo $SERVICE | jq -r '.pendingCount')
    
    print_status "Service Status: $STATUS"
    print_status "Desired Tasks: $DESIRED_COUNT"
    print_status "Running Tasks: $RUNNING_COUNT"
    print_status "Pending Tasks: $PENDING_COUNT"
    
    # Check if service is healthy
    if [ "$STATUS" == "ACTIVE" ] && [ "$RUNNING_COUNT" -eq "$DESIRED_COUNT" ]; then
        print_status "ECS service is healthy"
        return 0
    else
        print_error "ECS service is unhealthy"
        return 1
    fi
}

# Function to check ECS tasks
check_ecs_tasks() {
    print_header "ECS Tasks Status"
    
    TASKS=$(aws ecs list-tasks \
        --cluster "${ENVIRONMENT}-jasmin-cluster" \
        --service-name jasmin-service \
        --region $REGION \
        --query 'taskArns' \
        --output text)
    
    if [ -z "$TASKS" ]; then
        print_error "No tasks found for jasmin-service"
        return 1
    fi
    
    for TASK_ARN in $TASKS; do
        TASK_DETAILS=$(aws ecs describe-tasks \
            --cluster "${ENVIRONMENT}-jasmin-cluster" \
            --tasks $TASK_ARN \
            --region $REGION \
            --query 'tasks[0]')
        
        TASK_ID=$(echo $TASK_DETAILS | jq -r '.taskArn | split("/") | last')
        STATUS=$(echo $TASK_DETAILS | jq -r '.lastStatus')
        HEALTH=$(echo $TASK_DETAILS | jq -r '.healthStatus // "N/A"')
        
        print_status "Task $TASK_ID: $STATUS (Health: $HEALTH)"
        
        # Check container status
        CONTAINERS=$(echo $TASK_DETAILS | jq -r '.containers[] | .name + ":" + .lastStatus')
        for CONTAINER in $CONTAINERS; do
            print_status "  Container $CONTAINER"
        done
    done
}

# Function to check load balancer health
check_load_balancer() {
    print_header "Load Balancer Health"
    
    ALB_DNS=$(get_alb_dns)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Get target group health
    TARGET_GROUPS=$(aws elbv2 describe-target-groups \
        --names "${ENVIRONMENT}-smpp-tg" "${ENVIRONMENT}-http-tg" "${ENVIRONMENT}-cli-tg" \
        --region $REGION \
        --query 'TargetGroups[].{Name:TargetGroupName,Arn:TargetGroupArn}' \
        --output json)
    
    for TG in $(echo $TARGET_GROUPS | jq -c '.[]'); do
        TG_NAME=$(echo $TG | jq -r '.Name')
        TG_ARN=$(echo $TG | jq -r '.Arn')
        
        # Get target health
        TARGET_HEALTH=$(aws elbv2 describe-target-health \
            --target-group-arn $TG_ARN \
            --region $REGION \
            --query 'TargetHealthDescriptions[].{Target:Target.Id,Health:TargetHealth.State}' \
            --output json)
        
        print_status "Target Group: $TG_NAME"
        
        if [ $(echo $TARGET_HEALTH | jq length) -eq 0 ]; then
            print_warning "  No targets registered"
        else
            for TARGET in $(echo $TARGET_HEALTH | jq -c '.[]'); do
                TARGET_ID=$(echo $TARGET | jq -r '.Target')
                HEALTH=$(echo $TARGET | jq -r '.Health')
                
                if [ "$HEALTH" == "healthy" ]; then
                    print_status "  Target $TARGET_ID: $HEALTH"
                else
                    print_error "  Target $TARGET_ID: $HEALTH"
                fi
            done
        fi
    done
}

# Function to check application endpoints
check_endpoints() {
    print_header "Application Endpoints Health"
    
    ALB_DNS=$(get_alb_dns)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Check HTTP API
    print_status "Testing HTTP API (port 1401)..."
    if curl -f -s -o /dev/null -w "HTTP %{http_code}" "http://$ALB_DNS:1401/ping" 2>/dev/null; then
        print_status "HTTP API is responding"
    else
        print_error "HTTP API is not responding"
    fi
    
    # Check SMPP port
    print_status "Testing SMPP port (2775)..."
    if timeout 5 bash -c "</dev/tcp/$ALB_DNS/2775" 2>/dev/null; then
        print_status "SMPP port is accessible"
    else
        print_error "SMPP port is not accessible"
    fi
    
    # Check CLI port
    print_status "Testing CLI port (8990)..."
    if timeout 5 bash -c "</dev/tcp/$ALB_DNS/8990" 2>/dev/null; then
        print_status "CLI port is accessible"
    else
        print_error "CLI port is not accessible"
    fi
}

# Function to check Redis status
check_redis() {
    print_header "Redis Status"
    
    REDIS_ENDPOINT=$(aws cloudformation describe-stacks \
        --stack-name "${ENVIRONMENT}-jasmin-stack" \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`RedisEndpoint`].OutputValue' \
        --output text)
    
    if [ -z "$REDIS_ENDPOINT" ] || [ "$REDIS_ENDPOINT" == "None" ]; then
        print_error "Could not retrieve Redis endpoint"
        return 1
    fi
    
    # Get Redis cluster status
    REDIS_STATUS=$(aws elasticache describe-replication-groups \
        --replication-group-id "${ENVIRONMENT}-redis" \
        --region $REGION \
        --query 'ReplicationGroups[0].Status' \
        --output text)
    
    print_status "Redis Endpoint: $REDIS_ENDPOINT"
    print_status "Redis Status: $REDIS_STATUS"
    
    if [ "$REDIS_STATUS" == "available" ]; then
        print_status "Redis cluster is available"
        return 0
    else
        print_error "Redis cluster is not available"
        return 1
    fi
}

# Function to check RabbitMQ status
check_rabbitmq() {
    print_header "RabbitMQ Status"
    
    RABBITMQ_ENDPOINT=$(aws cloudformation describe-stacks \
        --stack-name "${ENVIRONMENT}-jasmin-stack" \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`RabbitMQEndpoint`].OutputValue' \
        --output text)
    
    if [ -z "$RABBITMQ_ENDPOINT" ] || [ "$RABBITMQ_ENDPOINT" == "None" ]; then
        print_error "Could not retrieve RabbitMQ endpoint"
        return 1
    fi
    
    # Get RabbitMQ broker status
    RABBITMQ_STATUS=$(aws mq describe-broker \
        --broker-id "${ENVIRONMENT}-rabbitmq" \
        --region $REGION \
        --query 'BrokerInstances[0].ConsoleURL' \
        --output text)
    
    print_status "RabbitMQ Endpoint: $RABBITMQ_ENDPOINT"
    
    if [ ! -z "$RABBITMQ_STATUS" ] && [ "$RABBITMQ_STATUS" != "None" ]; then
        print_status "RabbitMQ broker is available"
        print_status "Management Console: $RABBITMQ_STATUS"
        return 0
    else
        print_error "RabbitMQ broker is not available"
        return 1
    fi
}

# Function to check CloudWatch logs
check_cloudwatch_logs() {
    print_header "CloudWatch Logs"
    
    LOG_GROUP="/ecs/${ENVIRONMENT}-jasmin"
    
    # Check if log group exists
    if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region $REGION &> /dev/null; then
        print_status "Log group exists: $LOG_GROUP"
        
        # Get recent log streams
        LOG_STREAMS=$(aws logs describe-log-streams \
            --log-group-name "$LOG_GROUP" \
            --order-by LastEventTime \
            --descending \
            --max-items 5 \
            --region $REGION \
            --query 'logStreams[].logStreamName' \
            --output text)
        
        if [ ! -z "$LOG_STREAMS" ]; then
            print_status "Recent log streams:"
            for STREAM in $LOG_STREAMS; do
                print_status "  $STREAM"
            done
        else
            print_warning "No log streams found"
        fi
    else
        print_error "Log group not found: $LOG_GROUP"
    fi
}

# Function to check CloudFormation stack
check_cloudformation_stack() {
    print_header "CloudFormation Stack Status"
    
    STACK_STATUS=$(aws cloudformation describe-stacks \
        --stack-name "${ENVIRONMENT}-jasmin-stack" \
        --region $REGION \
        --query 'Stacks[0].StackStatus' \
        --output text)
    
    print_status "Stack Status: $STACK_STATUS"
    
    if [[ "$STACK_STATUS" == *"COMPLETE"* ]]; then
        print_status "CloudFormation stack is healthy"
        return 0
    else
        print_error "CloudFormation stack is not healthy"
        return 1
    fi
}

# Function to display summary
display_summary() {
    print_header "Monitoring Summary"
    
    ALB_DNS=$(get_alb_dns)
    if [ $? -eq 0 ]; then
        print_status "Application Load Balancer: $ALB_DNS"
        print_status "SMPP Endpoint: $ALB_DNS:2775"
        print_status "HTTP API Endpoint: $ALB_DNS:1401"
        print_status "CLI Endpoint: $ALB_DNS:8990"
    fi
    
    print_status "Environment: $ENVIRONMENT"
    print_status "Region: $REGION"
    print_status "Timestamp: $(date)"
}

# Main monitoring function
main() {
    print_header "Jasmin Routing System - Health Check"
    print_status "Environment: $ENVIRONMENT"
    print_status "Region: $REGION"
    echo
    
    # Check prerequisites
    check_aws_cli
    
    # Initialize counters
    TOTAL_CHECKS=0
    PASSED_CHECKS=0
    
    # Run all checks
    if check_cloudformation_stack; then
        ((PASSED_CHECKS++))
    fi
    ((TOTAL_CHECKS++))
    echo
    
    if check_ecs_service; then
        ((PASSED_CHECKS++))
    fi
    ((TOTAL_CHECKS++))
    echo
    
    check_ecs_tasks
    echo
    
    if check_load_balancer; then
        ((PASSED_CHECKS++))
    fi
    ((TOTAL_CHECKS++))
    echo
    
    if check_endpoints; then
        ((PASSED_CHECKS++))
    fi
    ((TOTAL_CHECKS++))
    echo
    
    if check_redis; then
        ((PASSED_CHECKS++))
    fi
    ((TOTAL_CHECKS++))
    echo
    
    if check_rabbitmq; then
        ((PASSED_CHECKS++))
    fi
    ((TOTAL_CHECKS++))
    echo
    
    check_cloudwatch_logs
    echo
    
    # Display summary
    display_summary
    echo
    
    # Final status
    if [ $PASSED_CHECKS -eq $TOTAL_CHECKS ]; then
        print_status "All critical checks passed! ($PASSED_CHECKS/$TOTAL_CHECKS)"
        exit 0
    else
        print_error "Some checks failed! ($PASSED_CHECKS/$TOTAL_CHECKS)"
        exit 1
    fi
}

# Run main function
main "$@"
