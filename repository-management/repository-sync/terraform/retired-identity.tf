# The legacy tenant no longer exists. Do not refresh or destroy its old objects.
removed {
  from = module.azure

  lifecycle {
    destroy = false
  }
}
