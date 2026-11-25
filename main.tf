# ==============================================================================
# INFRAESTRUCTURA COMO CÓDIGO (TERRAFORM) - GOOGLE CLOUD PLATFORM (GCP)
# Arquitectura Multi-Ambiente (PROD, DEV, QA) + Integración Azure AI Foundry
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# ------------------------------------------------------------------------------
# VARIABLES DE CONFIGURACIÓN
# ------------------------------------------------------------------------------
variable "project_id" {
  description = "arquitecturacloud-fignalo"
  type        = string
}

variable "region" {
  description = "southamerica-west1"
  type        = string
  default     = "southamerica-west1"
}

variable "zone" {
  description = "southamerica-west1-a"
  type        = string
  default     = "southamerica-west1-a"
}

variable "environment" {
  description = "Ambiente a desplegar: prod, dev o qa"
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "dev", "qa"], var.environment)
    error_message = "El ambiente debe ser 'prod', 'dev' o 'qa'."
  }
}

# Configuración de Azure AI Foundry (Endpoints externos)
variable "azure_ai_foundry_endpoint" {
  description = "https://arquitecturacloud-fignalo-foundry-prod.services.ai.azure.com"
  type        = string
  default     = "https://arquitecturacloud-fignalo-foundry-prod.services.ai.azure.com"
}

variable "azure_ai_foundry_api_key" {
  description = "AZURE_AI_FOUNDRY_API_KEY"
  type        = string
  sensitive   = true
}

# Configuración de VPN hacia On-Premise y Puestos Fronterizos (Solo PROD)
variable "onpremise_vpn_peer_ip" {
  description = "192.172.1.0"
  type        = string
  default     = "192.172.1.0"
}

variable "fronterizos_vpn_peer_ip" {
  description = "192.172.0.128"
  type        = string
  default     = "192.172.0.128"
}

variable "vpn_shared_secret" {
  description = "PSK_IPSEC_SEGURO"
  type        = string
  sensitive   = true
  default     = "PSK_IPSEC_SEGURO"
}

variable "db_password" {
  description = "PASSWORD_SQL"
  type        = string
  sensitive   = true
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ------------------------------------------------------------------------------
# HABILITACIÓN DE APIS NECESARIAS EN GCP
# ------------------------------------------------------------------------------
locals {
  required_apis = [
    "compute.googleapis.com",
    "vpcaccess.googleapis.com",
    "servicenetworking.googleapis.com",
    "run.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "iap.googleapis.com",
    "dns.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com"
  ]

  # Definición exacta de subredes según los 3 diagramas
  network_config = {
    prod = {
      vpc_cidr = "10.0.0.0/22"
      subnets = {
        waf           = "10.0.0.208/29" # Application Gateway + WAF (Cloud Armor + LB)
        firewall      = "10.0.0.216/29" # Firewall / Egreso controlado
        frontend      = "10.0.0.128/27" # Portales Ciudadanos y Funcionarios
        backend       = "10.0.0.160/27" # Cloud Run Backend API
        datos         = "10.0.0.224/29" # Cloud SQL + Cloud Storage
        consultas     = "10.0.0.0/26"   # Cloud Function Consulta Antecedentes
        preproc_ia    = "10.0.0.64/26"  # Cloud Function Procesamiento Documentos
        ia_endpoint   = "10.0.0.192/28" # Conectividad hacia Azure AI Foundry
      }
      onpremise_cidrs   = ["192.172.1.0/28"]
      fronterizos_cidrs = ["192.172.0.0/24"]
    }
    dev = {
      vpc_cidr = "10.1.0.0/22"
      subnets = {
        firewall      = "10.1.0.48/29"  # Subred Entrada / Firewall
        frontend      = "10.1.0.0/28"   # Frontend DEV
        backend       = "10.1.0.16/28"  # Backend DEV
        datos         = "10.1.0.56/29"  # Datos DEV
        integracion   = "10.1.0.32/28"  # Integración DEV (Functions)
        simuladores   = "10.1.0.64/29"  # Simuladores B3000 y GEPOL
        ia_endpoint   = "10.1.0.80/28"  # Subred IA DEV -> Azure AI Foundry
      }
      onpremise_cidrs   = []
      fronterizos_cidrs = []
    }
    qa = {
      vpc_cidr = "10.2.0.0/16"
      subnets = {
        frontend      = "10.2.0.0/26"   # Frontend QA
        backend       = "10.2.0.64/26"  # Backend QA
        datos         = "10.2.1.0/27"   # Datos QA
        integracion   = "10.2.0.128/26" # Integración QA (Functions)
        simuladores   = "10.2.1.32/27"  # Simuladores QA
        ia_endpoint   = "10.2.1.64/27"  # Subred IA QA -> Azure AI Foundry
      }
      onpremise_cidrs   = []
      fronterizos_cidrs = []
    }
  }

  current_net = local.network_config[var.environment]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.required_apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "random_id" "suffix" {
  byte_length = 3
}

# ==============================================================================
# 1. RED VIRTUAL (VPC) Y SUBREDES POR AMBIENTE
# ==============================================================================
resource "google_compute_network" "vpc" {
  name                    = "vpc-fignalo-${var.environment}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnets" {
  for_each                 = local.current_net.subnets
  name                     = "snet-${var.environment}-${each.key}"
  ip_cidr_range            = each.value
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Conectores Serverless VPC Access (Para que Cloud Run / Cloud Functions usen las subredes)
resource "google_vpc_access_connector" "backend_connector" {
  name          = "conn-be-${var.environment}"
  region        = var.region
  subnet {
    name = google_compute_subnetwork.subnets["backend"].name
  }
  min_instances = 2
  max_instances = 3
  depends_on    = [google_project_service.apis]
}

resource "google_vpc_access_connector" "ia_connector" {
  name          = "conn-ia-${var.environment}"
  region        = var.region
  subnet {
    name = google_compute_subnetwork.subnets["ia_endpoint"].name
  }
  min_instances = 2
  max_instances = 3
  depends_on    = [google_project_service.apis]
}

# Cloud Router y Cloud NAT para salida controlada hacia APIs externas y Azure AI Foundry
resource "google_compute_router" "router" {
  name    = "router-fignalo-${var.environment}"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat-fignalo-${var.environment}"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Reglas de Firewall internas y salida hacia Azure AI Foundry + Organismos Públicos
resource "google_compute_firewall" "allow_internal" {
  name    = "fw-${var.environment}-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "1433", "5432"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = concat(
    [local.current_net.vpc_cidr],
    local.current_net.onpremise_cidrs,
    local.current_net.fronterizos_cidrs
  )
}

resource "google_compute_firewall" "allow_egress_external_apis" {
  name      = "fw-${var.environment}-egress-https"
  network   = google_compute_network.vpc.name
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  # Permite HTTPS saliente hacia Azure AI Foundry, Registro Civil, SERVEL, INTERPOL, Migraciones y ClaveÚnica
  destination_ranges = ["0.0.0.0/0"]
}

# ==============================================================================
# 2. CONECTIVIDAD HÍBRIDA VPN (SOLO PRODUCCIÓN: ON-PREMISE Y PUESTOS FRONTERIZOS)
# ==============================================================================
resource "google_compute_vpn_gateway" "vpn_gw" {
  count   = var.environment == "prod" ? 1 : 0
  name    = "vpngw-fignalo-dmz-prod"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_address" "vpn_static_ip" {
  count  = var.environment == "prod" ? 1 : 0
  name   = "ip-vpn-fignalo-prod"
  region = var.region
}

resource "google_compute_forwarding_rule" "fr_esp" {
  count       = var.environment == "prod" ? 1 : 0
  name        = "fr-esp-prod"
  ip_protocol = "ESP"
  ip_address  = google_compute_address.vpn_static_ip[0].address
  target      = google_compute_vpn_gateway.vpn_gw[0].id
}

resource "google_compute_forwarding_rule" "fr_udp500" {
  count       = var.environment == "prod" ? 1 : 0
  name        = "fr-udp500-prod"
  ip_protocol = "UDP"
  port_range  = "500"
  ip_address  = google_compute_address.vpn_static_ip[0].address
  target      = google_compute_vpn_gateway.vpn_gw[0].id
}

resource "google_compute_forwarding_rule" "fr_udp4500" {
  count       = var.environment == "prod" ? 1 : 0
  name        = "fr-udp4500-prod"
  ip_protocol = "UDP"
  port_range  = "4500"
  ip_address  = google_compute_address.vpn_static_ip[0].address
  target      = google_compute_vpn_gateway.vpn_gw[0].id
}

# Túnel 1: Cloud <-> On-Premise (B3000 / GEPOL - 192.172.1.0/28)
resource "google_compute_vpn_tunnel" "tunnel_onpremise" {
  count                   = var.environment == "prod" ? 1 : 0
  name                    = "tunnel-onpremise-dmz"
  peer_ip                 = var.onpremise_vpn_peer_ip
  shared_secret           = var.vpn_shared_secret
  target_vpn_gateway      = google_compute_vpn_gateway.vpn_gw[0].id
  local_traffic_selector  = [local.current_net.vpc_cidr]
  remote_traffic_selector = local.current_net.onpremise_cidrs

  depends_on = [
    google_compute_forwarding_rule.fr_esp,
    google_compute_forwarding_rule.fr_udp500,
    google_compute_forwarding_rule.fr_udp4500,
  ]
}

resource "google_compute_route" "route_onpremise" {
  count       = var.environment == "prod" ? 1 : 0
  name        = "route-to-onpremise"
  network     = google_compute_network.vpc.name
  dest_range  = local.current_net.onpremise_cidrs[0]
  priority    = 1000
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.tunnel_onpremise[0].id
}

# Túnel 2: Cloud <-> Puestos Fronterizos PDI (192.172.0.0/24)
resource "google_compute_vpn_tunnel" "tunnel_fronterizos" {
  count                   = var.environment == "prod" ? 1 : 0
  name                    = "tunnel-puestos-fronterizos"
  peer_ip                 = var.fronterizos_vpn_peer_ip
  shared_secret           = var.vpn_shared_secret
  target_vpn_gateway      = google_compute_vpn_gateway.vpn_gw[0].id
  local_traffic_selector  = [local.current_net.vpc_cidr]
  remote_traffic_selector = local.current_net.fronterizos_cidrs

  depends_on = [
    google_compute_forwarding_rule.fr_esp,
    google_compute_forwarding_rule.fr_udp500,
    google_compute_forwarding_rule.fr_udp4500,
  ]
}

resource "google_compute_route" "route_fronterizos" {
  count       = var.environment == "prod" ? 1 : 0
  name        = "route-to-fronterizos"
  network     = google_compute_network.vpc.name
  dest_range  = local.current_net.fronterizos_cidrs[0]
  priority    = 1000
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.tunnel_fronterizos[0].id
}

# ==============================================================================
# 3. SECRET MANAGER (CREDENCIALES AZURE AI FOUNDRY Y BASE DE DATOS)
# ==============================================================================
resource "google_secret_manager_secret" "azure_ai_key" {
  secret_id = "azure-ai-foundry-key-${var.environment}"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "azure_ai_key_val" {
  secret      = google_secret_manager_secret.azure_ai_key.id
  secret_data = var.azure_ai_foundry_api_key
}

# ==============================================================================
# 4. CAPA DE DATOS Y ALMACENAMIENTO (SUBRED DATOS)
# ==============================================================================
# Peering privado para Cloud SQL (evita exposición pública)
resource "google_compute_global_address" "private_ip_sql" {
  name          = "psa-sql-${var.environment}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_sql.name]
}

# Instancia Cloud SQL (Equivalente a Azure SQL + Réplica/HA en PROD)
resource "google_sql_database_instance" "main_db" {
  name             = "sql-fignalo-${var.environment}-${random_id.suffix.hex}"
  database_version = "SQLSERVER_2022_STANDARD"
  region           = var.region
  root_password    = var.db_password

  settings {
    tier              = var.environment == "prod" ? "db-custom-4-16384" : "db-custom-2-4096"
    availability_type = var.environment == "prod" ? "REGIONAL" : "ZONAL" # Alta disponibilidad en PROD

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }

    backup_configuration {
      enabled            = true
      start_time         = "03:00"
      point_in_time_recovery_enabled = var.environment == "prod"
    }
  }

  deletion_protection = var.environment == "prod" ? true : false
  depends_on          = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_database" "tramites_db" {
  name     = "fignalo_${var.environment}"
  instance = google_sql_database_instance.main_db.name
}

# Cloud Storage para Documentos (Equivalente a Azure Files)
resource "google_storage_bucket" "documentos_bucket" {
  name                        = "fignalo-documentos-${var.environment}-${random_id.suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.environment != "prod"

  versioning {
    enabled = var.environment == "prod"
  }
}

# ==============================================================================
# 5. CAPA FRONTEND Y WAF (PORTAL CIUDADANOS Y PORTAL FUNCIONARIOS)
# ==============================================================================
# Buckets para alojar Portales Estáticos (Equivalente a Azure Static Web Apps)
resource "google_storage_bucket" "portal_ciudadanos" {
  name                        = "fignalo-portal-ciudadanos-${var.environment}-${random_id.suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = false
  force_destroy               = var.environment != "prod"

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

resource "google_storage_bucket" "portal_funcionarios" {
  name                        = "fignalo-portal-funcionarios-${var.environment}-${random_id.suffix.hex}"
  location                    = var.region
  uniform_bucket_level_access = false
  force_destroy               = var.environment != "prod"

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

# Política WAF (Cloud Armor - Equivalente a Application Gateway + WAF en PROD)
resource "google_compute_security_policy" "waf_policy" {
  count = var.environment == "prod" ? 1 : 0
  name  = "waf-fignalo-ciudadanos-prod"

  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable') || evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
    description = "Bloqueo OWASP SQLi y XSS"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Regla por defecto permitir tráfico válido"
  }
}

# ==============================================================================
# 6. CAPA DE CÓMPUTO: BACKEND API Y MICROSERVICIOS DE INTEGRACIÓN / IA
# ==============================================================================
resource "google_service_account" "app_sa" {
  account_id   = "sa-fignalo-workloads-${var.environment}"
  display_name = "Service Account Workloads PDI (${var.environment})"
}

resource "google_secret_manager_secret_iam_member" "sa_secret_access" {
  secret_id = google_secret_manager_secret.azure_ai_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app_sa.email}"
}

# Backend API para Consultas (Equivalente a App Service Backend API)
resource "google_cloud_run_v2_service" "backend_api" {
  name     = "api-backend-consultas-${var.environment}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.app_sa.email

    vpc_access {
      connector = google_vpc_access_connector.backend_connector.id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello" # Reemplazar por imagen real del Backend API

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "DB_HOST"
        value = google_sql_database_instance.main_db.private_ip_address
      }
      env {
        name  = "STORAGE_BUCKET"
        value = google_storage_bucket.documentos_bucket.name
      }
    }
  }
}

# Microservicio 1: Consulta de Antecedentes (Equivalente a Function App Consulta de Antecedentes)
resource "google_cloud_run_v2_service" "fn_consulta_antecedentes" {
  name     = "fn-consulta-antecedentes-${var.environment}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.app_sa.email

    vpc_access {
      connector = google_vpc_access_connector.backend_connector.id
      egress    = "ALL_TRAFFIC" # Enruta hacia VPN On-Premise y APIs externas vía NAT
    }

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello" # Reemplazar por imagen de la función

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "REGISTRO_CIVIL_URL"
        value = var.environment == "prod" ? "https://api.registrocivil.gob.cl" : "https://sim-regcivil.dev.local"
      }
      env {
        name  = "INTERPOL_URL"
        value = var.environment == "prod" ? "https://api.interpol.int" : "https://sim-interpol.dev.local"
      }
    }
  }
}

# Microservicio 2: Procesamiento de Documentos -> Endpoint Azure AI Foundry
resource "google_cloud_run_v2_service" "fn_procesamiento_ia" {
  name     = "fn-procesamiento-ia-${var.environment}"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.app_sa.email

    # Conectado a la Subred de IA para egreso dedicado hacia Azure AI Foundry
    vpc_access {
      connector = google_vpc_access_connector.ia_connector.id
      egress    = "ALL_TRAFFIC"
    }

    containers {
      image = "us-docker.pkg.dev/cloudrun/container/hello" # Reemplazar por imagen OCR/IA

      env {
        name  = "ENVIRONMENT"
        value = var.environment
      }
      env {
        name  = "AZURE_AI_FOUNDRY_ENDPOINT"
        value = var.azure_ai_foundry_endpoint
      }
      env {
        name  = "AZURE_AI_FOUNDRY_API_VERSION"
        value = "2024-10-21"
      }
      env {
        name = "AZURE_AI_FOUNDRY_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.azure_ai_key.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "DOCUMENTOS_BUCKET"
        value = google_storage_bucket.documentos_bucket.name
      }
      env {
        name  = "DB_HOST"
        value = google_sql_database_instance.main_db.private_ip_address
      }
    }
  }
}

# ==============================================================================
# 7. SIMULADORES INSTITUCIONALES (SOLO DEV Y QA: B3000 Y GEPOL SIMULADOS)
# ==============================================================================
resource "google_compute_instance" "simuladores_institucionales" {
  count        = var.environment != "prod" ? 1 : 0
  name         = "vm-simuladores-b3000-gepol-${var.environment}"
  machine_type = "e2-medium"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnets["simuladores"].id
    # Sin IP pública: solo accesible dentro de la VPC por la función de antecedentes
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update && apt-get install -y docker.io
    systemctl enable --now docker
    # Aquí se despliegan los contenedores mock de B3000 y GEPOL
  EOF
}

# ==============================================================================
# OUTPUTS DE DESPLIEGUE
# ==============================================================================
output "vpc_id" {
  value = google_compute_network.vpc.id
}

output "subnets_cidr" {
  value = { for k, s in google_compute_subnetwork.subnets : k => s.ip_cidr_range }
}

output "backend_api_url" {
  value = google_cloud_run_v2_service.backend_api.uri
}

output "fn_procesamiento_ia_url" {
  value = google_cloud_run_v2_service.fn_procesamiento_ia.uri
}

output "azure_ai_foundry_target" {
  value = var.azure_ai_foundry_endpoint
}

output "cloud_sql_private_ip" {
  value = google_sql_database_instance.main_db.private_ip_address
}

output "vpn_gateway_public_ip" {
  value = var.environment == "prod" ? google_compute_address.vpn_static_ip[0].address : "N/A (Solo PROD)"
}
