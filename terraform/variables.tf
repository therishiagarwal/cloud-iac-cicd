variable "project" {
  type    = string
  default = "tf-jenkins-demo"
}

variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

variable "key_pair_name" {
  type    = string
  default = "tfjenkins-key"
}
