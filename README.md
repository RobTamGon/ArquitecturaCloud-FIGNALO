# Despliegue de Infraestructura GCP + Azure AI Foundry con Terraform

Este paquete implementa en **Google Cloud Platform (GCP)** los tres ambientes corregidos de los diagramas (`PROD`, `DEV` y `QA`), integrando el procesamiento documental hacia los **Endpoints de Azure AI Foundry**.

## 1. Mapeo de Arquitectura (Azure -> GCP + Azure AI Foundry)

| Componente en Diagrama | Servicio en GCP / Híbrido |
| :--- | :--- |
| VNet / Subredes (`10.0.0.0/22`, `10.1.0.0/22`, `10.2.0.0/16`) | VPC Network + Subnets dedicadas + Serverless VPC Connectors |
| Application Gateway + WAF (`PROD`) | Cloud Armor (Políticas OWASP SQLi/XSS) |
| Firewall + Salida externa | Cloud Firewall + Cloud Router + Cloud NAT |
| VPN Gateway a DMZ / Puestos Fronterizos (`PROD`) | Cloud VPN Gateway + Túneles IPsec (`192.168.1.0/28` y `192.168.0.0/24`) |
| Static Apps (Portal Ciudadanos y Funcionarios) | Cloud Storage Static Website Hosting |
| App Service Backend API | Cloud Run (`api-backend-consultas`) |
| Function Apps (Antecedentes y Procesamiento) | Cloud Run privado (`fn-consulta-antecedentes` y `fn-procesamiento-ia`) |
| SQL + Files | Cloud SQL (SQL Server 2022 HA en PROD) + Cloud Storage |
| Servicio de IA (Extracción de datos) | **Endpoint externo de Azure AI Foundry** + Secret Manager |
| Simuladores B3000 y GEPOL (`DEV` y `QA`) | Compute Engine VM privada en subred de simuladores |

## 2. Requisitos Previos
1. **Terraform** `>= 1.6.0` instalado.
2. **Google Cloud CLI (`gcloud`)** instalado y autenticado.
3. Un proyecto activo en GCP con facturación habilitada.
4. Un recurso activo de **Azure AI Foundry** con su URL de Endpoint y API Key.

## 3. Pasos de Ejecución
1. Autenticarse en GCP:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   gcloud config set project arquitecturacloud-fignalo
   ```
2. Configurar variables:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
3. Inicializar, validar y aplicar:
   ```bash
   terraform init
   terraform fmt -check
   terraform validate
   terraform plan -var-file="terraform.tfvars" -out=tfplan
   terraform apply "tfplan"
   ```
4. Despliegue multi-ambiente (opcional mediante Workspaces):
   ```bash
   terraform workspace new dev
   terraform apply -var="environment=dev" -var-file="terraform.tfvars"

   terraform workspace new qa
   terraform apply -var="environment=qa" -var-file="terraform.tfvars"

   terraform workspace new prod
   terraform apply -var="environment=prod" -var-file="terraform.tfvars"
   ```
