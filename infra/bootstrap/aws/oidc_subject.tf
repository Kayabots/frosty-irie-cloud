# GitHub OIDC subject: see README > Bootstrap AWS > "GitHub OIDC subject format".
variable "github_oidc_subject" {
  description = "Repository part of the GitHub OIDC 'sub' claim. Repositories created or renamed after 15 July 2026 use the immutable form OWNER@OWNER_ID/REPO@REPO_ID (copy it from the AADSTS700213 error or the GitHub OIDC settings). Empty uses github_repository (the older name-only form)."
  type        = string
  default     = ""
}

locals {
  # Pinning to the immutable IDs means a deleted-and-recreated repo or org with the same name cannot assume these roles.
  gh_sub_repo = var.github_oidc_subject != "" ? var.github_oidc_subject : var.github_repository
}
