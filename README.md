# Jasmin Routing System

## Introduction
This system is designed for Jasmin SMPP Gateway to route any Mobile Terminated SMPP Request to the client's Provider like Telecom.

## Run
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