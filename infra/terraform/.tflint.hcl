config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

# Naming: lowercase snake_case everywhere, no exceptions.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Every variable and output must be documented — the module interface IS the docs.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Unpinned providers turn a routine apply into an unplanned upgrade.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_module_pinned_source" {
  enabled = true
  style   = "flexible"
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

# Deprecated interpolation-only expressions ("${var.x}") — noise in diffs.
rule "terraform_deprecated_interpolation" {
  enabled = true
}
