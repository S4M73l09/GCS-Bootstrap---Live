# Gcloud-Bootstrap-live

## Objetivo  
Separar Bootstrap (infra base y seguridad) de Live (infra real) con Terraform + GitHub Actions + Workload Identity Federation (WIF) — sin claves JSON, bloqueo por rama main y restricciones por IDs de GitHub.  

### 0) Visión general (qué es cada cosa)

Proyecto GCP **“Bootstrap”**  
Infra base y seguridad: bucket de tfstate, Service Account (SA) “runner” y WIF (pool + provider) para GitHub.
➜ Cambia muy poco; es la plataforma.

Proyecto GCP “Live”
Infra “real” (redes, VMs, IAM, etc.). Se aplica desde su repo con Terraform.
➜ Cambia a menudo; es tu entorno.

Repos GitHub (recomendado separarlos)

+ ***GCS-Bootstrap---Live*** → solo Bootstrap

+ ***GCS-Live*** → solo Live

### 1) Bootstrap — paso a paso
#### 1.1 Crear el proyecto y activar APIs

* Crea el proyecto Bootstrap en la consola o con gcloud.

* Activa estas APIs en el proyecto Bootstrap:
```pgsql
serviceusage, iam, iamcredentials, sts, storage, cloudresourcemanager
```

#### 1.2 Bucket GCS para tfstate

* Crea gs://"bootstrap-project"-tfstate (con versioning ON; retención opcional).

* No lo hagas público; acceso uniforme por bucket.

***Por qué:*** estado remoto consistente y con versiones para “deshacer”.

#### 1.3 Service Account “runner” (Terraform)

* Crea terraform-bootstrap@<bootstrap-project>.iam.gserviceaccount.com.

* Permisos mínimos sobre el bucket (leer/escribir el estado).
  
   *  El resto de permisos (p.ej. sobre el proyecto Live) se darán después y solo donde aplique.

***Por qué:*** esta SA será el “identidad en GCP” de las pipelines.

#### 1.4 Workload Identity Federation (WIF)

1) Pool (p.ej. github-pool-2).
2) Provider OIDC (p.ej. *github-provider*) con:  
   * Issuer: https://token.actions.githubusercontent.com/
   * Attribute mapping:  

   ```pgsql
   google.subject      = assertion.sub
   attribute.repository= assertion.repository
   attribute.actor     = assertion.actor
   attribute.ref       = assertion.ref
   ```  

***Por qué:*** GitHub emite un token OIDC; GCP lo valida y emite credenciales sin usar claves JSON.

#### 1.5 Seguridad fina: condición en el provider (no en el binding)

* Aplica attributeCondition en el provider (WIF) para limitar por ID de repo y rama main:  
```ini
assertion.repository_id == '<NUMERIC_REPO_ID>' &&
assertion.ref == 'refs/heads/main'
```  

(Opcional, aún más estricto):  
```pgsql
&& assertion.repository_owner_id == '<NUMERIC_OWNER_ID>'
```  
***Por qué:*** evitar typosquatting (nombres casi iguales) y ejecutar solo en main.  
   * Los IDs los obtienes desde la API de GitHub ***(/repos/OWNER/REPO y /users/OWNER → campo id).***

#### 1.6 Binding de la SA (sin condición)

* Otorga a la SA ***terraform-"project-name"@... el rol roles/iam.workloadIdentityUser*** con member:  
```php-template
principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/attribute.repository/<OWNER>/<REPO>
```  
* Sin condición en el binding (la restricción ya la hace el provider).

***Por qué:*** la lógica de seguridad vive en el provider (donde sí existen assertion.*).  

**Cuidado** En bindings de IAM no existe attribute.* (de ahí el error “undeclared reference”).

Asi que ten cuidado a la hora de planificar este paso.

#### 1.7 Secrets de GitHub (repo Bootstrap)

Crea solo dos:

* TF_SA_EMAIL  
```css
terraform-bootstrap@PROJECT_ID_NAME.iam.gserviceaccount.com
```  

* WIF_PROVIDER  
```bash
projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool-2/providers/github-provider
```  
**(Opcional)** GOOGLE_CLOUD_PROJECT=PROJECT_NAME.

***Por qué:*** el action google-github-actions/auth@v2 necesita el provider path y la SA.

Todos estos credenciales se pueden alojar en los secrets del repositorio de Github y llamarlo mediantes sus variables, asi no se deja rastro de datos sensibles.

#### 1.8 Backend de Terraform (Bootstrap)

backend.tf:
```hcl
terraform {
  backend "gcs" {
    bucket = "PROJECTNAMEtfstate"
    prefix = "global/PREFIX"
  }
}
```  
***Por qué:*** Terraform guardará su estado en el bucket del Bootstrap.

#### 1.9 Workflow de GitHub Actions (Bootstrap)
.github/workflows/bootstrap.yml (Sujeto a cambios):    

Workflow Plan
```yaml
name: Bootstrap-Plan

on:
  push:
    branches: [ "main" ]
    paths:   [ "Bootstrap/**" ]
  pull_request:
    paths:   [ "Bootstrap/**" ]
  workflow_dispatch: {}

permissions:
  id-token: write
  contents: read

concurrency:
  group: bootstrap-plan
  cancel-in-progress: true

defaults:
  run:
    working-directory: ./Bootstrap

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Debug GitHub claims
        run: |
          echo "GITHUB_REPOSITORY     = $GITHUB_REPOSITORY"
          echo "GITHUB_REPOSITORY_ID  = $GITHUB_REPOSITORY_ID"
          echo "GITHUB_REF            = $GITHUB_REF"

      - name: Auth to GCP via WIF
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
          service_account:           ${{ secrets.TF_SA_EMAIL }}

      - name: Debug ADC
        run: gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.8.5

      - name: Terraform Init
        run: terraform init -input=false

      # 0 = no changes, 2 = changes, 1 = error
      - name: Terraform Plan (detailed exit code)
        id: plan
        shell: bash
        run: |
          set +e
          terraform plan -input=false -lock-timeout=3m -out=tfplan -detailed-exitcode
          ec=$?
          echo "exitcode=$ec" >> $GITHUB_OUTPUT
          if [ "$ec" -eq 2 ]; then
            echo "changed=true"  >> $GITHUB_OUTPUT
            exit 0
          elif [ "$ec" -eq 0 ]; then
            echo "changed=false" >> $GITHUB_OUTPUT
            exit 0
          else
            exit $ec
          fi

      - name: Upload tfplan artifact
        if: steps.plan.outputs.changed == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: tfplan
          path: tfplan
          retention-days: 3
```
Workflow Apply
```yaml
name: Bootstrap-Apply

on:
  workflow_run:
    workflows: ["Bootstrap-Plan"]   # nombre EXACTO del workflow de plan
    types: [completed]
    branches: [main]

permissions:
  id-token: write
  contents: read
  actions: read                     # necesario para listar/descargar artefactos

concurrency:
  group: bootstrap-apply
  cancel-in-progress: true

defaults:
  run:
    working-directory: ./Bootstrap

jobs:
  check-and-apply:
    # Solo si el Plan terminó OK
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Debug GitHub context
        run: |
          echo "PLAN RUN ID           = ${{ github.event.workflow_run.id }}"
          echo "GITHUB_REPOSITORY     = $GITHUB_REPOSITORY"
          echo "GITHUB_REPOSITORY_ID  = $GITHUB_REPOSITORY_ID"
          echo "GITHUB_REF            = $GITHUB_REF"

      # ¿Existe artefacto "tfplan" en el run del Plan?
      - name: Find tfplan artifact
        id: find
        uses: actions/github-script@v7
        with:
          script: |
            const run_id = ${{ github.event.workflow_run.id }};
            const { data } = await github.rest.actions.listWorkflowRunArtifacts({
              owner: context.repo.owner,
              repo:  context.repo.repo,
              run_id
            });
            const a = data.artifacts.find(x => x.name === 'tfplan' && !x.expired);
            core.setOutput('has_tfplan', a ? 'true' : 'false');

      - name: No changes, skipping
        if: ${{ steps.find.outputs.has_tfplan != 'true' }}
        run: echo "No tfplan artifact -> no changes. Skipping apply."

      # === Solo si hay cambios ===
      - name: Auth to GCP via WIF
        if: ${{ steps.find.outputs.has_tfplan == 'true' }}
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ secrets.WIF_PROVIDER }}
          service_account:           ${{ secrets.TF_SA_EMAIL }}

      - name: Setup Terraform
        if: ${{ steps.find.outputs.has_tfplan == 'true' }}
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.8.5

      - name: Terraform Init
        if: ${{ steps.find.outputs.has_tfplan == 'true' }}
        run: terraform init -input=false

      - name: Download tfplan from Plan run
        if: ${{ steps.find.outputs.has_tfplan == 'true' }}
        uses: actions/download-artifact@v4
        with:
          name: tfplan
          path: Bootstrap
          run-id: ${{ github.event.workflow_run.id }}

      # Gate de aprobación manual SOLO si hay cambios
      - name: Require approval
        if: ${{ steps.find.outputs.has_tfplan == 'true' }}
        environment: bootstrap        # configura reviewers en Settings → Environments → bootstrap
        run: echo "Awaiting approval…"

      - name: Check for destroy actions
        if: ${{ steps.find.outputs.has_tfplan == 'true' }}
        run: |
          terraform show -no-color tfplan | grep -q '^- ' && {
            echo "ERROR: Plan includes destroy, refusing to auto-apply"
            exit 1
          } || echo "No destroy detected"

      - name: Terraform Apply
        if: ${{ steps.find.outputs.has_tfplan == 'true' }}
        run: terraform apply -input=false -lock-timeout=3m -auto-approve tfplan


```  
  ***Por qué:*** solo se ejecuta en main, autentica por WIF, fija versión de Terraform y evita carreras.

### 2) Backend y configuracion de Terraform (Bootstrap)  
**Opción minima**: si no quieres gestionar Bootstrap con Terraform, solo se deja el backend para futuras ampliaciones.

* ***backend.tf***
```hcl
terraform {
  backend "gcs" {
    bucket = "bootstrap-476212-tfstate"
    prefix = "bootstrap/terraform/state"
  }
}
```  
* ***versions.tf***  
```hcl
terraform {
  required_version = ">= 1.5.0, < 2.0.0"
}
```  
**No se gestiona este mismo bucket en este estado (si no aparece bucle)**

#### 2.1) (Opcional recomendado) Codificar Bootstrap como IaC  
Colocar archivos de terraform en la carpeta [Bootstrap](/Bootstrap/) para que terraform gestione: SA, WIF Pool/Provider y el binding.

(Repito que el bucket del backend no se gestione aqui.)
```css
repo/
└─ Bootstrap/
   ├─ backend.tf
   ├─ versions.tf
   ├─ providers.tf
   ├─ main.tf
   └─ terraform.tfvars
```  
***/Bootstrap/backend.tf***
```hcl
terraform {
  backend "gcs" {
    bucket = "bootstrap-476212-tfstate"
    prefix = "bootstrap/iac/state"
  }
}
```  
***/Bootstrap/versions.tf***
```hcl
terraform {
  required_version = ">= 1.5.0, < 2.0.0"
  required_providers {
    google      = { source = "hashicorp/google",      version = "~> 5.40" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.40" }
  }
}
```  
***Bootstrap/providers.tf***

***Bootstrap/main.tf***

***Bootstrap/terraform.tfvars.bootstrap***

Estos archivos los puedes ver en la carpeta mencionada.

Ademas de poder añadir un ***.gitignore***
```csharp
# Terraform
.terraform/
.terraform.lock.hcl
*.tfstate
*.tfstate.*
crash.log
override.tf
override.tf.json
*.override.tf
*.override.tf.json

# Variables reales
```  
#### 2.2) Importar lo existente al estado (Esto se hace una sola vez)
```bash
cd Bootstrap
terraform init

terraform import google_service_account.runner \
"projects/bootstrap-476212/serviceAccounts/terraform-bootstrap@bootstrap-476212.iam.gserviceaccount.com"

terraform import google_iam_workload_identity_pool.pool \
"projects/bootstrap-476212/locations/global/workloadIdentityPools/github-pool-2"

terraform import google_iam_workload_identity_pool_provider.provider \
"projects/bootstrap-476212/locations/global/workloadIdentityPools/github-pool-2/providers/github-provider"

# Importa el biding (sin usar member para evitar bug)
terraform import google_service_account_iam_binding.wif_binding \
"projects/bootstrap-476212/serviceAccounts/terraform-bootstrap@bootstrap-476212.iam.gserviceaccount.com roles/iam.workloadIdentityUser"


terraform plan
# terraform apply  (solo si queremos alinear detalles de nombres/labels)
```  

#### 2.3) Protección del bucket ***tfstate***
```bash
BUCKET="bootstrap-476212-tfstate"
TF_SA="terraform-bootstrap@bootstrap-476212.iam.gserviceaccount.com"

# PAP enforced + UBLA + versioning + retención 30d
gcloud storage buckets update gs://$BUCKET --pap
gcloud storage buckets update gs://$BUCKET --uniform-bucket-level-access
gcloud storage buckets update gs://$BUCKET --versioning
gcloud storage buckets update gs://$BUCKET --retention-period 30d

# Permisos a la SA (objetos)
gcloud storage buckets add-iam-policy-binding gs://$BUCKET \
  --member="serviceAccount:$TF_SA" --role="roles/storage.objectAdmin"

# (Opcional) Restringir a un prefix concreto del state
PREFIX="bootstrap/iac/state/"
gcloud storage buckets add-iam-policy-binding gs://$BUCKET \
  --member="serviceAccount:$TF_SA" --role="roles/storage.objectAdmin" \
  --condition="title=tfstate-prefix,expression=resource.name.startsWith('projects/_/buckets/$BUCKET/objects/$PREFIX')"

# Verificar
gcloud storage buckets describe gs://$BUCKET \
  --format="yaml(iamConfiguration,versioning,retentionPolicy)"
```  
#### 2.4) Verificaciones útiles

Podemos verificar si todo los comandos y permisos hemos puesto, funciona.
```bash
# Provider (issuer + condition + mapping)
gcloud iam workload-identity-pools providers describe github-provider \
  --project=bootstrap-476212 --location=global \
  --workload-identity-pool=github-pool-2 \
  --format="yaml(oidc.issuerUri,attributeCondition,attributeMapping)"

# Binding de la SA
gcloud iam service-accounts get-iam-policy \
  terraform-bootstrap@bootstrap-476212.iam.gserviceaccount.com \
  --project=bootstrap-476212 --format=yaml
```
## 3) Roles finales necesarias que necesita la service Account del pipeline Bootstrap

La service account que usa el workflow (**terraform-bootstrap@...**) debe tener IAM del proyecto:

* Creador de tokens de cuenta de servicio.  
  <roles/iam.serviceAccountTokenCreator>  
* Usuario de identidades de cargas de trabajo  
  <roles/iam.workloadIdentityUser>  
* Administrador de cuenta de servicio  
  <roles/iam.serviceAccountAdmin>  
* Administrador de grupos de Workload Identity de IAM(Beta)  
  <roles/iam.workloadIdentityPoolAdmin>  

Eso es lo que desbloquea:

* Lectura/escritura de IAM en la service account  
* lectura/gestion del Workload Identity Poll y Provider  
* emision de OIDC  
* impersonacion  

### 3.1) Componentes que ya gestionas vía Terraform (IaC real)

Terraform ahora mismo ya es dueño de:  

* la service account runner (o importada)  
* los binding IAM (google_service_account_iam_member)  
* el workload Identity Pool y Provider (incluyendo las condiciones CEL con repo_id y rama)  
* el resto de infra del proyecto  

Eso significa que repetir este setup en otro proyecto cloud es, básicamente:

* Crear proyecto vacio  
* dar a la nueva SA permisos equivalentes  
* correr terraform  

Esto industrializa el Bootstrap

## 4) Troubleshooting (ultra resumido)

* OIDC con GitHub Actions y Google Cloud  
Al ejecutar el workflow de Terraform en GitHub Actions con autenticación OIDC contra Google Cloud, fallaba la parte de autenticación con este error:  
```text
ERROR: (gcloud.auth.application-default.print-access-token) There was a problem refreshing your current auth tokens: ('Unable to acquire impersonated credentials'. 
"Permission 'iam.serviceAccounts.getAccessToken' denied on resource (or it may not exist)." 
status: "PERMISSION_DENIED"
permission: "iam.serviceAccounts.getAccessToken"
)
```  
Este es un fallo de comunicacion, a la hora de crear los atributos necesarios para el uso del token OIDC, Github esperaba un token que no llegaba debido a que dichos atributos estaban configurados para que viesen el nombre del repositorio y no por id como se tenia planeado.

Para solucionarlo, se añadieron dos lineas atributo para que la comunicacion de Github Actions y google fuese efectiva y escuchase por id mas que por nombre.  

      Ir a IAM & Admin → Workload Identity Federation → [mi pool] → [mi provider OIDC] → Editar.

En "Asignación de atributos" añadí estas líneas nuevas:
```text
attribute.repository_id = assertion.repository_id
attribute.actor_id      = assertion.actor_id   # opcional, solo si quieres atarlo también al usuario que dispara el workflow
```  
Luego, en "Condiciones de atributos" añadí una condición CEL para restringir quién puede autenticarse:
```cel
assertion.repository_id == '1083637831' && assertion.ref == 'refs/heads/main'
```  
Esto significa:

  + Solo el repo con el id Real puede comunicarse
  + y solo con la rama main

Asi evito forks o ramas random usen mi identidad de Google Cloud.

y por ultimo dar acceso a la Service Account desde su propia pagina.  
En Google Console o por CLI, esto ya va a gusto de cualquiera:  

  + Ir a IAM & Admin → Service Accounts.
  + Entrar en la service account usada por Terraform (ej: terraform-bootstrap@...).
  +  Ir a la pestaña "Principales con acceso" (esto es quién puede usarla/impersonarla).
  +  Pulsar "➕ Otorgar acceso".

En el campo "Nuevos principales" añadí un principal con este formato:
```text
principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_NAME/attribute.repository_id/1083637831
```  
Donde:
  + PROJECT_NUMBER = número interno del proyecto de GCP (no el ID legible, el número largo).
  + POOL_NAME = el nombre de mi Workload Identity Pool.
  + 1083637831 = el repository_id del repo real de GitHub (lo saqué con curl https://api.github.com/repos/OWNER/REPO).  
Guardar

Después, a ese principal le asigné SOLO estos dos roles sobre la service account:  
  + roles/iam.workloadIdentityUser (Usuario de identidades de cargas de trabajo)
  * roles/iam.serviceAccountTokenCreator (Creador de tokens de cuenta de servicio)  
Guardar  

Despues de esto, el paso de usar OIDC funciono sin problemas, iniciando Terraform.

-----

* Error en argumento gcloud set  
Debido a que ya Terraform se autentica, no es necesario tener dicho argumento en el workflow por que da error, lo mejor es que Terraform se autentique solo con los datos dados.
----

* Error en el uso de IAM por falta de api
Este error se soluciona activando una API necesaria: 
```bash
gcloud services enable iamcredentials.googleapis.com --project bootstrap-476212
```  
----
* Añadimos el rol Service Account Token Creator a la SA para el principal de WIF:
```hcl
# Binding WIF existente (se mantiene)
resource "google_service_account_iam_binding" "wif_binding" {
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.workloadIdentityUser"
  members            = [ local.principal_member ]
}

# ➕ Permiso para emitir access tokens
resource "google_service_account_iam_binding" "wif_token_creator" {
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  members            = [ local.principal_member ]
}
```  
----
* Import ultimo que fallaba
Cannot find binding ... al importar google_service_account_iam_member.
Se soluciona importando por rol, asi se soluciona:
```hcl
resource "google_service_account_iam_binding" "wif_binding" { ... }
```  
```bash
terraform import google_service_account_iam_binding.wif_binding \
"projects/bootstrap-476212/serviceAccounts/terraform-bootstrap@bootstrap-476212.iam.gserviceaccount.com roles/iam.workloadIdentityUser"
```  
---

* Issuer incorrecto  
Debe ser exacto: https://token.actions.githubusercontent.com/.

* “undeclared reference to 'attribute'” en binding  
No uses attribute.* en el binding. Mueve la condición al provider con assertion.*.  
(Alternativa: en el binding usa google.subject con startsWith('repo:OWNER/REPO:ref:...').)

* Provider no se crea
Crea mínimo google.subject=assertion.sub y luego actualiza el mapping; o hazlo por API REST.

* 403 desde GitHub
Verifica:

  * attributeCondition del provider (IDs correctos y refs/heads/main).

  * WIF_PROVIDER y TF_SA_EMAIL en secrets.

  * Workflow se ejecuta en main y permissions: id-token: write.


## 4) Buenas prácticas clave

* Sin JSON keys (solo WIF).

* Dos repos: Bootstrap y Live.

* Provider con condición por ID + main (evita typosquatting).

* Condicion en el provider (assertion.*) — no en el binding.

* Binding sin condición (menos fricción, lógica en el provider).

* Permisos mínimos en Live y branch protection en GitHub.

* Mantener el bucket ***tfstate*** en el proyecto Bootstrap y con PAP + UBLA + versioning

Toda informacion sacada de mi propia experiencia y aprendizaje, ademas de verificar guias oficiales de Google Cloud.

## Referencias oficiales

### Google Cloud
- Configure WIF para pipelines (GitHub Actions, etc.): https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines  :contentReference[oaicite:0]{index=0}
- Workload Identity Federation (conceptos): https://docs.cloud.google.com/iam/docs/workload-identity-federation  :contentReference[oaicite:1]{index=1}
- Blog GCP: autenticación “keyless” desde GitHub Actions: https://cloud.google.com/blog/products/identity-security/enabling-keyless-authentication-from-github-actions  :contentReference[oaicite:2]{index=2}

### GitHub (OIDC + Actions)
- OpenID Connect en GitHub Actions (overview): https://docs.github.com/en/actions/concepts/security/openid-connect  :contentReference[oaicite:3]{index=3}
- OpenID Connect reference (claims como `sub`, `repository_id`, `ref`, etc.): https://docs.github.com/actions/reference/openid-connect-reference  :contentReference[oaicite:4]{index=4}
- Configurar OIDC específicamente con Google Cloud (guía + workflow): https://docs.github.com/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-google-cloud-platform  :contentReference[oaicite:5]{index=5}
- Configurar OIDC en proveedores cloud (vista general): https://docs.github.com/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-cloud-providers  :contentReference[oaicite:6]{index=6}
- Acción oficial para autenticarse en Google Cloud (`google-github-actions/auth`): https://github.com/google-github-actions/auth  :contentReference[oaicite:7]{index=7}
- Marketplace de la acción `auth`: https://github.com/marketplace/actions/authenticate-to-google-cloud  :contentReference[oaicite:8]{index=8}

### GitHub REST API (para obtener IDs numéricos y evitar typosquatting)
- Documentación REST API (overview): https://docs.github.com/en/rest  :contentReference[oaicite:9]{index=9}
- Endpoint de repos (para `repository_id`): https://docs.github.com/en/rest/repos/repos  :contentReference[oaicite:10]{index=10}
- Endpoint de usuarios (para `repository_owner_id` si lo necesitas): https://docs.github.com/en/rest/users/users  :contentReference[oaicite:11]{index=11}


