#########################################
eks_version     = "1.31"
instance_type   = "c6i.large"
ami_description = "Amazon EKS Kubernetes AMI based on AmazonLinux2023 OS"

ami_block_device_mappings = [
  {
    device_name = "/dev/xvda"
    volume_size = 40
  },
]

launch_block_device_mappings = [
  {
    device_name = "/dev/xvda"
    volume_size = 40
  }
]

shell_provisioner1 = {
  expect_disconnect = true
  scripts = [
    "scripts/wasm-runtimes.sh",
    "scripts/cleanup.sh"
  ]
  environment_vars = [
    "spin_shim_download_url=https://github.com/spinkube/containerd-shim-spin/releases/download/v0.15.1/containerd-shim-spin-v2-linux-x86_64.tar.gz"
  ]
}
