# Jasmin Routing System

## Introduction
This system is designed for Jasmin SMPP Gateway to route any Mobile Terminated SMPP Request to the client's Provider like Telecom.

## Local Development

### 1. Environment file
Place your .env file into the Project folder. Replace your actual API_KEY with the property.
```properties
API_KEY=SOMETHING
```

### 2. Docker
Compose the project:
```bash
docker compose up -d
```

## AWS Deployment

This project includes complete AWS deployment automation with external Redis and RabbitMQ services.

### Quick Start

1. **Prerequisites**
   - AWS CLI installed and configured
   - Docker installed
   - jq installed for JSON parsing

2. **Deploy to AWS**
   ```bash
   # Deploy to production (EU Central - Frankfurt)
   ./aws/scripts/deploy.sh production eu-central-1
   
   # Deploy to staging (EU Central - Frankfurt)
   ./aws/scripts/deploy.sh staging eu-central-1
   ```

3. **Monitor Application**
   ```bash
   ./aws/scripts/monitor.sh production eu-central-1
   ```

4. **Update Application**
   ```bash
   ./aws/scripts/update-application.sh production eu-central-1
   ```

5. **Cleanup (when needed)**
   ```bash
   ./aws/scripts/cleanup.sh production eu-central-1
   ```

### Architecture

The AWS deployment creates:

- **ECS Fargate Cluster** running Jasmin application
- **Application Load Balancer** for traffic distribution
- **ElastiCache Redis** for caching and session storage
- **Amazon MQ RabbitMQ** for message queuing
- **VPC with public/private subnets** for network security
- **Security Groups** for access control
- **CloudWatch Logs** for monitoring
- **AWS Secrets Manager** for secure credential storage

### Access Points

After deployment, your application will be available at:
- **SMPP**: `ALB_DNS:2775`
- **HTTP API**: `ALB_DNS:1401`
- **CLI**: `ALB_DNS:8990`

### Documentation

For detailed AWS deployment documentation, see [aws/README.md](aws/README.md).

## Services

### Local Development
- **Jasmin SMPP Gateway**: Port 2775
- **HTTP API**: Port 1401
- **CLI Interface**: Port 8990
- **Redis**: Port 6379
- **RabbitMQ**: Port 5672 (AMQP), 15672 (Management UI)

### AWS Production
- **Jasmin SMPP Gateway**: Load balanced on port 2775
- **HTTP API**: Load balanced on port 1401
- **CLI Interface**: Load balanced on port 8990
- **Redis**: ElastiCache cluster with encryption
- **RabbitMQ**: Amazon MQ with SSL encryption

## Configuration

### Environment Variables
```bash
# Jasmin Configuration
JASMIN_INTERFACES=sm-http
API_KEY=<your-api-key>

# Redis Configuration (Local)
REDIS_HOST=localhost
REDIS_PORT=6379

# RabbitMQ Configuration (Local)
RABBITMQ_HOST=localhost
RABBITMQ_PORT=5672
```

### AWS Environment Variables
```bash
# Redis Configuration (AWS)
REDIS_HOST=<elasticache-endpoint>
REDIS_PORT=6379
REDIS_PASSWORD=<from-secrets-manager>

# RabbitMQ Configuration (AWS)
RABBITMQ_HOST=<amazon-mq-endpoint>
RABBITMQ_PORT=5671
RABBITMQ_USE_SSL=true
RABBITMQ_USERNAME=<from-secrets-manager>
RABBITMQ_PASSWORD=<from-secrets-manager>
```

## Monitoring

### Local Development
- Check container logs: `docker logs jasmin`
- Monitor Redis: `docker exec -it redis redis-cli`
- Monitor RabbitMQ: Access http://localhost:15672 (admin/admin)

### AWS Production
- CloudWatch Logs: `/ecs/{environment}-jasmin`
- ECS Service monitoring via AWS Console
- Load Balancer health checks
- Use monitoring script: `./aws/scripts/monitor.sh`

## Security

### Local Development
- Services run in Docker containers
- Default credentials for development

### AWS Production
- All services in private subnets
- SSL/TLS encryption for RabbitMQ
- Redis encryption at rest and in transit
- IAM roles with least privilege
- Secrets stored in AWS Secrets Manager
- Security groups with minimal required access

## Troubleshooting

### Local Issues
1. Check if all containers are running: `docker ps`
2. View logs: `docker logs <container-name>`
3. Restart services: `docker compose restart`

### AWS Issues
1. Check CloudWatch logs
2. Verify security group rules
3. Test connectivity between services
4. Use monitoring script for health checks
5. Check ECS task status in AWS Console

## Support

For issues or questions:
1. Check the logs for error messages
2. Verify configuration and environment variables
3. Test connectivity between services
4. Review AWS CloudFormation stack events (for AWS deployment)