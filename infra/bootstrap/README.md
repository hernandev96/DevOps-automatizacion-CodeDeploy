# 🚀 Infraestructura Bootstrap (Terraform State Backend & GitHub Actions OIDC)

Este módulo aprovisiona los recursos fundacionales necesarios para gestionar la infraestructura del proyecto con **Terraform** y habilitar la autenticación segura desde **GitHub Actions**:

1. **Bucket S3 para Backend Remoto:** Almacena de forma centralizada, segura y versionada el archivo `terraform.tfstate` de `infra/main`.
2. **Tabla DynamoDB de Bloqueo (State Locking):** Evita ejecuciones concurrentes o colisiones cuando múltiples desarrolladores o pipelines ejecutan `terraform apply`.
3. **Proveedor de Identidad OIDC de GitHub Actions:** Permite que los workflows de GitHub Actions se autentiquen directamente contra AWS sin necesidad de almacenar credenciales de larga duración (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).
4. **Rol IAM para GitHub Actions:** Rol configurado con política de confianza OIDC (`AssumeRoleWithWebIdentity`) y permisos para aprovisionar y destruir los recursos de `infra/main` y desplegar la aplicación.

---

## 📋 Requisitos Previos

- [AWS CLI v2](https://aws.amazon.com/cli/) instalado y configurado con credenciales de administrador (`aws configure`).
- [Terraform](https://www.terraform.io/) (versión >= 1.0) instalado.

---

## 🛠️ Instrucciones de Despliegue de Bootstrap

### 1. Inicializar y Aplicar

```bash
cd infra/bootstrap

# 1. Inicializar proveedores
terraform init

# 2. Validar configuración
terraform validate

# 3. Planificar y aplicar
terraform apply
```

> [!NOTE]
> Si en tu cuenta de AWS ya existía previamente el proveedor OIDC `token.actions.githubusercontent.com`, la variable `create_oidc_provider` viene configurada por defecto en `false`, por lo que Terraform utilizará un `data source` sin generar conflictos de duplicación (`EntityAlreadyExists`).

---

### 2. Configurar GitHub Actions

La trust policy valida dos claims del token OIDC de GitHub Actions:

- `aud`: `sts.amazonaws.com`.
- `sub`: los valores definidos en `github_subject_claims`, incluyendo los identificadores `@` de organización y repositorio requeridos por esta cuenta.

Para cambiar los repositorios, ramas o eventos autorizados, sobrescribe `github_subject_claims` en `terraform.tfvars`. Los valores deben coincidir exactamente con el claim `sub` emitido por GitHub.

Al finalizar `terraform apply`, obtendrás el ARN del rol IAM en los outputs:

```bash
terraform output -raw github_actions_role_arn
```

Copia este valor y configúralo en tu repositorio de GitHub:

1. Ve a **Settings → Secrets and variables → Actions → Variables**.
2. Añade o actualiza la variable:
   - **Nombre:** `AWS_ROLE_ARN`
   - **Valor:** El ARN obtenido (ej. `arn:aws:iam::123456789012:role/GitHubActionsMainDeployRole`).

---

### 3. Activar el Backend Remoto en `infra/main`

Copia el bloque generado en el output `backend_config_snippet`:

```bash
terraform output backend_config_snippet
```

Edita [`infra/main/main.tf`](../main/main.tf) y actualiza el bloque `backend "s3"` dentro de `terraform {}`:

```hcl
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "<NOMBRE_DEL_BUCKET_GENERADO>"
    key            = "main/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "calculadora-terraform-locks"
    encrypt        = true
  }
}
```

Luego inicializa y migra tu estado local al bucket S3:

```bash
cd ../main
terraform init -migrate-state
```
