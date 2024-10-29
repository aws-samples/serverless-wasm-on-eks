# Run Serverless WebAssembly workloads with Knative on Amazon EKS

This repository contains code to demonstrate how to run serverless WebAssembly workloads with Knative on Amazon EKS.
You will build custom AMIs that include the [Spin](https://github.com/fermyon/spin) runtime and then deploy an EKS cluster. After that you will deploy Knative, as well as build and deploy an example webshop application that is built using Wasm.

> **Note**
> The code in this repository does not provide you with a production ready EKS cluster or setup in general.
> To run a production ready EKS cluster, [please adhere to the best-practices AWS has defined](https://aws.github.io/aws-eks-best-practices/).
> In order to make this experience as easy as possible for you, the Kubernetes API of this sample will be reachable from the public internet.
> The webshop application will be exposed over the public internet without any authentication.
> This is not recommended in production.

---

## 🔢 Pre-requisites

You must have the following tools installed on your system:
  * AWS CLI (version 2.18.0 or later)
    * [Installing AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html#getting-started-install-instructions)
  * Packer (version 1.11.0 or later)
    * [Installing Packer](https://developer.hashicorp.com/packer/tutorials/docker-get-started/get-started-install-cli)
  * Terraform (version 1.9.0 or later)
    * [Installing Terraform](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)
  * Kubectl (version 1.31.x)
    * [Installing Kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
  * Helm (version 3.16.0 or later)
    * [Installing Helm](https://helm.sh/docs/intro/install/)
  * Spin
    * [Installing Spin](https://developer.fermyon.com/spin/v2/install)
  * Rust
    * [Installing Rust](https://www.rust-lang.org/tools/install)
  * Cloning the repo to your environment

The easiest way to authenticate Packer and Terraform is [through setting up authentication in the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-authentication.html). Please keep in mind that you will need many permissions to setup this environment. It is assumed that the credentials you use have administrator permissions.

To test if your AWS CLI works and you are authenticated, run this command:
```
aws sts get-caller-identity --output json
````

The output should look like this:
```
{
    "UserId": "UUID123123:your_user",
    "Account": "111122223333",
    "Arn": "arn:aws:sts::111122223333:assumed-role/some-role/your_user"
}
```
Take note of your account-id, as you will need it later.

> **Note**
> The default instance type to build the AMI and the EKS cluster does not qualify for the AWS free tier.
> You are charged for any instances created when building this AMI and the EKS cluster.
> An EKS cluster in itself does not qualify for the AWS free tier as well.
> You are charged for any EKS cluster you deploy while building this sample.

## 👷 Building the application and its infrastructure

This project includes a Makefile to simplify the build and deployment process. The Makefile automates several steps, making it easier for you to set up the entire environment.

To build the project, simply run:

```bash
make all
```

> **Note**: Make sure you have all the prerequisites installed and your AWS credentials properly configured before running the Makefile commands

### What the Makefile does for you:

- **AMI Creation**: Builds a custom Amazon Machine Image (AMI) that includes the Spin runtime.
- **Infrastructure Deployment**: Uses Terraform to create the EKS cluster and necessary AWS resources.
- **Knative Setup**: Installs and configures Knative on your EKS cluster.
- **Application Deployment**: Builds the WebAssembly-based webshop application and deploys it to the cluster.

The entire process takes approximately 30 minutes to complete.

## 🧪 Testing the application

After successfully deploying the infrastructure and application, you can test the serverless capabilities of your WebAssembly workload. Follow these steps:

1. First, check that no application pods are running initially:

   ```bash
   kubectl get pods -A
   ```

   You should see no pods related to your webshop application.

2. Visit the URL of your webshop application in the browser: webshop.default.example.com. Try shopping for unicorns, adding some to your cart, viewing your cart and deleting items again.
   You'll notice that:
   * The first request might take a moment as Knative scales up from zero.
   * Subsequent requests should be faster as the pod is now running.

4. While using the webshop, check the pods again:

   ```bash
   kubectl get pods -n default
   ```

   You should now see one or more pods running for your webshop application.

5. After a period of inactivity (60 seconds), check the pods again:

   ```bash
   kubectl get pods -n default
   ```

   You'll notice that Knative has scaled the application back to zero pods, demonstrating the serverless nature of the setup.

This demonstrates how Knative automatically scales your WebAssembly workload based on demand, starting from zero and scaling back to zero when there's no traffic.
Cold starts should be noticeably shorter than for a traditional container based application.

## 🧹 Cleaning up

When you're done experimenting with the serverless WebAssembly workload, you can clean up all the resources to avoid unnecessary AWS charges. To do this, run:

```bash
make clean
```


This command will:
* Remove the deployed application
* Uninstall Knative from the EKS cluster
* Destroy the EKS cluster and related AWS resources using Terraform
* Delete the custom AMI created with Packer

The cleanup process takes approximately 15 minutes to complete.

> **Important**: Make sure to run the cleanup process to avoid ongoing charges for the EKS cluster and related resources.

## 🔒 Security

For security issues or concerns, please do not open an issue or pull request on GitHub. Please report any suspected or confirmed security issues to AWS Security https://aws.amazon.com/security/vulnerability-reporting/

## ⚖️ License Summary

This sample code is made available under a modified MIT license. See the LICENSE file.
