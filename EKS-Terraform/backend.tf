terraform {
  backend "s3" {
    bucket       = "k8demowithveeraecommerce"
    key          = "terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}
