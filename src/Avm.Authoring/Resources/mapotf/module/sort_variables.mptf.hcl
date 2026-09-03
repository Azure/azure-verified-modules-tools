data "variable" "for_file_sort" {}

locals {
  vars = data.variable.for_file_sort.result

  # Each variable's target file: stay in its current file if that file already
  # matches the canonical `*variables*.tf` pattern; otherwise route to
  # `variables.tf`. This preserves multi-file layouts like
  # `variables.diagnostics.tf`, `variables.share.tf`, etc. while still
  # consolidating stray variables that live in `main.tf` or similar.
  vars_with_tf = {
    for n, v in local.vars : n => {
      v = v
      target_file = (
        length(regexall("variables.*\\.tf$", try(v.mptf.range.file_name, ""))) > 0
        ? v.mptf.range.file_name
        : "variables.tf"
      )
    }
  }

  var_target_files = distinct([for n, vf in local.vars_with_tf : vf.target_file])

  # Per-target-file ordered list: required (no `default`) alpha, then optional alpha.
  ordered_vars_by_file = {
    for f in local.var_target_files : f => concat(
      sort([for n, vf in local.vars_with_tf : n if vf.target_file == f && !contains(keys(vf.v), "default")]),
      sort([for n, vf in local.vars_with_tf : n if vf.target_file == f && contains(keys(vf.v), "default")]),
    )
  }
}

# Per-file sort. One transform per file that currently holds at least one variable
# (canonical `*variables*.tf` files preserve their split; strays land in `variables.tf`).
# Within each file: required-alpha then optional-alpha.
transform "sort_blocks_in_file" "vars_per_file" {
  for_each      = local.ordered_vars_by_file
  file_name     = each.key
  desired_order = [for n in each.value : "variable.${n}"]
}
