terraform {
  backend "s3" {
    bucket       = "devncloudtechdevops1111111111"
    key          = "terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
  }
}
