terraform {
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "0.8.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.36.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "2.17.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "3.2.4"
    }
  }

  required_version = ">= 1.0.0"
}
