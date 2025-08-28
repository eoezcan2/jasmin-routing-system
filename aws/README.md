# Jasmin Routing System - AWS Deployment

This directory contains all the necessary files and scripts to deploy the Jasmin Routing System on AWS ECS with external Redis and RabbitMQ services.

## Architecture Overview

The deployment creates a complete AWS infrastructure with the following components:

### Infrastructure Components
- **VPC** with public and private subnets across 2 availability zones
- **Application Load Balancer** for traffic distribution
- **ECS Fargate Cluster** for running the Jasmin application
- **ElastiCache Redis** cluster for caching and session storage
- **Amazon MQ RabbitMQ** broker for message queuing
- **Security Groups** for network security
- **IAM Roles** for service permissions
- **CloudWatch Logs** for application logging
- **AWS Secrets Manager** for secure credential storage

### Application Components
- **Jasmin SMPP Gateway** running on ECS Fargate
- **Load Balancer** exposing ports:
  - 2775 (SMPP)
  - 1401 (HTTP API)
  - 8990 (CLI)

## Prerequisites

Before deploying, ensure you have:

1. **AWS CLI** installed and configured with appropriate permissions
2. **Docker** installed for building and pushing images
3. **jq** installed for JSON parsing (used in deployment scripts)
4. **AWS Account** with sufficient permissions for:
   - CloudFormation
   - ECS
   - ECR
   - ElastiCache
   - Amazon MQ
   - IAM
   - VPC
   - Secrets Manager
   - CloudWatch Logs

## Quick Start

### 1. Configure AWS CLI
```bash
aws configure
```

### 2. Deploy the Application
```bash
# Deploy to production environment (EU Central - Frankfurt)
./aws/scripts/deploy.sh production eu-central-1

# Deploy to staging environment (EU Central - Frankfurt)
./aws/scripts/deploy.sh staging eu-central-1
```

### 3. Access Your Application
After deployment, you'll get the ALB DNS name. Access your application at:
- **SMPP**: `ALB_DNS:2775`
- **HTTP API**: `ALB_DNS:1401`
- **CLI**: `ALB_DNS:8990`

## Deployment Process

The deployment script (`deploy.sh`) performs the following steps:

1. **Create AWS Secrets Manager secrets** for Redis, RabbitMQ, and API keys
2. **Create ECR repository** and push Docker image
3. **Deploy CloudFormation stack** with all infrastructure
4. **Create ECS task role** with necessary permissions
5. **Register ECS task definition** with external service connections
6. **Create ECS service** with load balancer integration
7. **Output connection details** for accessing the application

## Infrastructure Details

### VPC Configuration
- **CIDR**: 10.0.0.0/16
- **Public Subnets**: 10.0.1.0/24, 10.0.2.0/24
- **Private Subnets**: 10.0.3.0/24, 10.0.4.0/24
- **NAT Gateway** for private subnet internet access

### Security Groups
- **ALB Security Group**: Allows inbound traffic on ports 80, 443, 2775, 1401, 8990
- **ECS Security Group**: Allows traffic from ALB to ECS tasks
- **Redis Security Group**: Allows Redis access from ECS tasks
- **RabbitMQ Security Group**: Allows RabbitMQ access from ECS tasks

### External Services

#### ElastiCache Redis
- **Engine**: Redis 6.x
- **Node Type**: cache.t3.micro
- **Encryption**: At-rest and in-transit enabled
- **Authentication**: Password-based with AWS Secrets Manager

#### Amazon MQ RabbitMQ
- **Engine**: RabbitMQ 3.10.20
- **Instance Type**: mq.t3.micro
- **SSL**: Enabled for secure connections
- **Authentication**: Username/password with AWS Secrets Manager

## Configuration

### Environment Variables
The application uses the following environment variables:

```bash
# Jasmin Configuration
JASMIN_INTERFACES=sm-http
API_KEY=<from-secrets-manager>

# Redis Configuration
REDIS_HOST=<elasticache-endpoint>
REDIS_PORT=6379
REDIS_PASSWORD=<from-secrets-manager>

# RabbitMQ Configuration
RABBITMQ_HOST=<amazon-mq-endpoint>
RABBITMQ_PORT=5671
RABBITMQ_USE_SSL=true
RABBITMQ_USERNAME=<from-secrets-manager>
RABBITMQ_PASSWORD=<from-secrets-manager>
```

### Scaling Configuration
- **ECS Service**: 2 desired tasks with auto-scaling
- **Load Balancer**: Health checks on all ports
- **Deployment**: Rolling updates with circuit breaker

## Monitoring and Logging

### CloudWatch Logs
- **Log Group**: `/ecs/{environment}-jasmin`
- **Retention**: 30 days
- **Log Driver**: awslogs

### Health Checks
- **HTTP API**: `GET /ping` on port 1401
- **SMPP**: TCP health check on port 2775
- **CLI**: TCP health check on port 8990

## Cost Optimization

### Resource Sizing
- **ECS Tasks**: 0.5 vCPU, 1GB RAM (Fargate)
- **Redis**: cache.t3.micro (single node)
- **RabbitMQ**: mq.t3.micro (single instance)
- **ALB**: Application Load Balancer (pay per request)

### Recommendations
- Use Fargate Spot for non-production workloads
- Consider reserved instances for production
- Monitor CloudWatch metrics for right-sizing
- Use S3 lifecycle policies for log retention

## Security

### Network Security
- All services in private subnets
- Security groups with minimal required access
- SSL/TLS encryption for RabbitMQ
- Redis encryption at rest and in transit

### Access Control
- IAM roles with least privilege
- Secrets stored in AWS Secrets Manager
- No hardcoded credentials in code

### Compliance
- All data encrypted at rest
- Network traffic encrypted in transit
- Audit logs enabled for RabbitMQ

## Troubleshooting

### Common Issues

#### ECS Tasks Not Starting
1. Check CloudWatch logs: `/ecs/{environment}-jasmin`
2. Verify task definition and service configuration
3. Check security group rules
4. Validate secrets in AWS Secrets Manager

#### Connection Issues
1. Verify security group rules allow traffic
2. Check VPC and subnet configuration
3. Validate endpoint URLs for Redis and RabbitMQ
4. Test connectivity from ECS tasks

#### Load Balancer Issues
1. Check target group health status
2. Verify security group allows ALB traffic
3. Check health check configuration
4. Validate port mappings

### Useful Commands

```bash
# Check ECS service status
aws ecs describe-services --cluster production-jasmin-cluster --services jasmin-service

# View CloudWatch logs
aws logs tail /ecs/production-jasmin --follow

# Check security group rules
aws ec2 describe-security-groups --group-names production-ecs-sg

# Test Redis connectivity
aws elasticache describe-replication-groups --replication-group-id production-redis

# Test RabbitMQ connectivity
aws mq describe-broker --broker-id production-rabbitmq
```

## Cleanup

To remove all AWS resources:

```bash
# Clean up all resources
./aws/scripts/cleanup.sh production us-east-1
```

**Warning**: This will delete ALL resources including data in Redis and RabbitMQ.

## File Structure

```
aws/
├── cloudformation/
│   └── infrastructure.yml    # Complete infrastructure template
├── ecs/
│   ├── task-definition.json  # ECS task definition template
│   └── service-definition.json # ECS service definition template
├── scripts/
│   ├── deploy.sh             # Deployment automation script
│   └── cleanup.sh            # Cleanup automation script
└── README.md                 # This documentation
```

## Support

For issues or questions:
1. Check CloudWatch logs for application errors
2. Review AWS CloudFormation stack events
3. Verify all prerequisites are met
4. Check AWS service limits and quotas

## Updates and Maintenance

### Updating the Application
1. Build and push new Docker image
2. Update ECS task definition
3. Update ECS service to use new task definition

### Infrastructure Updates
1. Modify CloudFormation template
2. Update stack with changes
3. Test in staging environment first

### Security Updates
1. Rotate secrets in AWS Secrets Manager
2. Update security group rules as needed
3. Apply security patches to base images
