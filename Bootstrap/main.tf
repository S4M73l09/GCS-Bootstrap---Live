locals {
  sa_id            = "terraform-bootstrap"
  sa_email         = "${local.sa_id}@${var.project_id}.iam.gserviceaccount.com"
  wif_location     = "global"
  principal_member = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/${local.wif_location}/workloadIdentityPools/${var.pool_id}/attribute.repository/${var.github_owner}/${var.github_repo}"
}

# --- Service Account (runner de Terraform) ---
resource "google_service_account" "runner" {
  account_id   = local.sa_id
  display_name = "Terraform Bootstrap Runner"
}

# --- Workload Identity Federation: Pool ---
resource "google_iam_workload_identity_pool" "pool" {
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub OIDC Pool"
}

# --- Workload Identity Federation: Provider ---
resource "google_iam_workload_identity_pool_provider" "provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.pool.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "GitHub Provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.actor"      = "assertion.actor"
    "attribute.ref"        = "assertion.ref"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  # Seguridad: limitar por repo_id y rama main
  attribute_condition = "assertion.repository_id=='${var.repo_id}' && assertion.ref=='${var.branch_ref}'"
}

# --- Binding: permitir al repo asumir la SA (sin condición; la restricción está en el provider) ---
resource "google_service_account_iam_binding" "wif_binding" {
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    local.principal_member
  ]

  resource "google_service_account_iam_binding" "wif_token_creator" {
  service_account_id = google_service_account.runner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  members            = [ local.principal_member ]
}

}
