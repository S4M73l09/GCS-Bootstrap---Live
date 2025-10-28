# variables.tf (recomendado separar de providers.tf)
variable "project_id" {
  type    = string
  default = "bootstrap-476212"
}

variable "pool_id" {
  type    = string
  default = "github-pool-2"
}

variable "provider_id" {
  type    = string
  default = "github-provider"
}

variable "github_owner" {
  type    = string
  default = "S4M73109"
}

variable "github_repo" {
  type    = string
  default = "GCS-Bootstrap---Live"
}

variable "repo_id" {
  type    = string
  default = "50858453" # ID numérico del repo, pero como string
}

variable "branch_ref" {
  type    = string
  default = "refs/heads/main"
}
