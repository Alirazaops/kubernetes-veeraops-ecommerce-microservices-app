terraform {
  backend "s3" {
    bucket       = "k8demowithveeraecommerce"
    key          = "terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
  }
}
