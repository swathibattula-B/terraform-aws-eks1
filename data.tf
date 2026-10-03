# Used to grant admin access to whoever runs terraform apply
data "aws_caller_identity" "current" {}
