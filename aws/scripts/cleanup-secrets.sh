#!/bin/bash

# Cleanup and recreate secrets with valid passwords

set -e

# Configuration
ENVIRONMENT=${1:-production}
REGION=${2:-eu-central-1}

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

# Function to cleanup and recreate secrets
cleanup_secrets() {
    print_status "Cleaning up and recreating secrets..."
    
    # Delete existing secrets
    for secret in "$ENVIRONMENT/redis" "$ENVIRONMENT/rabbitmq" "$ENVIRONMENT/jasmin"; do
        if aws secretsmanager describe-secret --secret-id "$secret" --region $REGION &> /dev/null; then
            print_warning "Deleting secret: $secret"
            aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery --region $REGION
            print_status "Secret deleted: $secret"
        fi
    done
    
    # Wait a moment for deletion to complete
    sleep 5
    
    # Recreate secrets with valid passwords
    print_status "Creating new secrets..."
    
    # Redis password
    aws secretsmanager create-secret \
        --name "$ENVIRONMENT/redis" \
        --description "Redis password for $ENVIRONMENT environment" \
        --secret-string '{"password":"'$(openssl rand -base64 32)'"}' \
        --region $REGION
    print_status "Redis secret created"
    
    # RabbitMQ credentials with valid password
    RABBITMQ_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
    aws secretsmanager create-secret \
        --name "$ENVIRONMENT/rabbitmq" \
        --description "RabbitMQ credentials for $ENVIRONMENT environment" \
        --secret-string "{\"username\":\"admin\",\"password\":\"$RABBITMQ_PASSWORD\"}" \
        --region $REGION
    print_status "RabbitMQ secret created with valid password"
    
    # Jasmin API key
    aws secretsmanager create-secret \
        --name "$ENVIRONMENT/jasmin" \
        --description "Jasmin API key for $ENVIRONMENT environment" \
        --secret-string '{"api_key":"'$(openssl rand -base64 32)'"}' \
        --region $REGION
    print_status "Jasmin API key secret created"
    
    print_status "All secrets recreated successfully!"
}

# Main function
main() {
    print_status "Jasmin Routing System - Secret Cleanup"
    print_status "Environment: $ENVIRONMENT"
    print_status "Region: $REGION"
    echo
    
    print_warning "This will delete and recreate all secrets for the $ENVIRONMENT environment."
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup_secrets
        print_status "Secret cleanup completed!"
    else
        print_status "Operation cancelled."
    fi
}

# Run main function
main "$@"
