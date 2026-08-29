terraform {
  # Only `key` is supplied at init time:
  #   -backend-config="key=fdp-infra-compute/<env>/terraform.tfstate"
  backend "s3" {
    bucket       = "fdp-infra-state-bucket-861477414666-eu-west-2-an"
    region       = "eu-west-2"
    use_lockfile = true
    encrypt      = true
  }
}
