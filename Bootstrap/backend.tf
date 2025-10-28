terraform {
  backend "gcs" {
    bucket = "bootstrap-476212-tfstate" # <-- tu bucket
    prefix = "bootstrap/iac/state"      # carpeta separada para este estado
  }
}
