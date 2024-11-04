# Makefile for demo setup

# Variables
PACKER_DIR := packer
TERRAFORM_DIR := terraform
KUBERNETES_DIR := kubernetes
APP_DIR := webshop
DEFAULT_REGION := $(shell aws configure get region 2>/dev/null)
REGION := $(DEFAULT_REGION)
AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text)
export PKR_VAR_tags := {"Environment":"serverless-wasm"}
export PKR_VAR_snapshot_tags := {"Environment":"serverless-wasm"}

# Default target
all: build-amis build-eks build-knative build-webshop

# Build AMIs using Packer and capture AMI IDs
build-amis:
	@echo "Building AMIs with Packer in region $(REGION)..."
	@cd $(PACKER_DIR) && \
	packer init -upgrade . && \
	packer build -var="region=$(REGION)" -var-file=al2023_amd64.pkrvars.hcl . && \
	packer build -var="region=$(REGION)" -var-file=al2023_arm64.pkrvars.hcl .

# Build EKS cluster using Terraform with AMI IDs from Packer
build-eks:
	@echo "Building EKS cluster with Terraform in region $(REGION)..."
	@cd $(TERRAFORM_DIR) && \
	export AMD64_AMI_ID=$$(aws ec2 describe-images --region $(REGION) --filters "Name=tag:Environment,Values=serverless-wasm" "Name=architecture,Values=x86_64" --query 'Images[*].ImageId' --output text) && \
	export ARM64_AMI_ID=$$(aws ec2 describe-images --region $(REGION) --filters "Name=tag:Environment,Values=serverless-wasm" "Name=architecture,Values=arm64" --query 'Images[*].ImageId' --output text) && \
	terraform init -upgrade && \
	terraform plan \
		-var="region=$(REGION)" \
		-var="custom_ami_id_amd64=$$AMD64_AMI_ID" \
		-var="custom_ami_id_arm64=$$ARM64_AMI_ID" && \
	terraform apply -auto-approve \
		-var="region=$(REGION)" \
		-var="custom_ami_id_amd64=$$AMD64_AMI_ID" \
		-var="custom_ami_id_arm64=$$ARM64_AMI_ID"

# Set kubectl context and deploy Knative
build-knative:
	@echo "Setting kubectl context and deploying Knative..."
	aws eks update-kubeconfig --region $(REGION) --name serverless-wasm && \
	cd $(KUBERNETES_DIR) && \
	kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.15.2/serving-crds.yaml && \
	kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.15.2/serving-core.yaml && \
	kubectl apply -f istio.yaml && \
	sleep 10 && \
	kubectl apply -f https://github.com/knative/net-istio/releases/download/knative-v1.15.1/net-istio.yaml && \
	kubectl patch configmap/config-features \
      --namespace knative-serving \
      --type merge \
      --patch '{"data":{"kubernetes.podspec-runtimeclassname": "enabled"}}' && \
    kubectl patch configmap/config-domain \
      --namespace knative-serving \
      --type merge \
      --patch '{"data":{"example.com":""}}' && \
	echo "Waiting for 180 seconds to allow Istio and AWS load balancer to start up..." && \
	sleep 180

# Build and deploy the example webshop
build-webshop:
	@echo "Building and deploying the example webshop..."
	aws ecr get-login-password --region eu-central-1 | \
	spin registry login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com
	@cd $(APP_DIR)/addToCart && \
	spin registry push --build $(AWS_ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com/addtocart:demo && \
	cd ../getCart && \
	spin registry push --build $(AWS_ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com/getcart:demo && \
	cd ../deleteFromCart && \
	spin registry push --build $(AWS_ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com/deletefromcart:demo && \
	cd ../static && \
	spin registry push --build $(AWS_ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com/webshop:demo && \
	cd ../../$(KUBERNETES_DIR) && \
	kubectl apply -f runtimeclass.yaml && \
	helm repo add bitnami https://charts.bitnami.com/bitnami && \
	helm repo update && \
	VALKEY_PW=$(shuf -er -n20  {A..Z} {a..z} {0..9} | tr -d '\n') && \
	helm install unicorn-valkey bitnami/valkey -f valkey-values.yaml --set auth.password=$$VALKEY_PW && \
	export REGION=$$(aws configure get region 2>/dev/null) && \
	export AWS_ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text) && \
	envsubst < knative-webshop.yaml | kubectl apply -f - && \
	export LB_DNS=$$(aws elbv2 describe-load-balancers \
	--query "LoadBalancers[?contains(DNSName, 'istio')].DNSName" \
	--output text) && \
	export LB_IP=$$(nslookup $$LB_DNS | tail -n 2 | awk '{print $2}') && \
	echo "Building the demo has finished" && \
	echo "Add this entry to your /etc/hosts: $$LB_IP webshop.default.example.com addtocart.default.example.com getcart.default.example.com deletefromcart.default.example.com" && \
	echo "Then visit webshop.default.example.com in your browser to try out Knative with Wasm"

# Clean up all oci images from the webshop
clean-webshop:
	@echo "Cleaning up OCI images..."
	@for repo in webshop addtocart deletefromcart getcart; do \
		echo "Deleting images from $$repo repository..."; \
		images=$$(aws ecr list-images --region $(REGION) --repository-name $$repo --query 'imageIds[*]' --no-cli-pager); \
		if [ "$$images" != "[]" ]; then \
			aws ecr batch-delete-image --region $(REGION) --repository-name $$repo --image-ids "$$images" --no-cli-pager|| true; \
		else \
			echo "No images found in $$repo repository."; \
		fi; \
	done
	
	aws eks update-kubeconfig --region $(REGION) --name serverless-wasm && \
	cd $(KUBERNETES_DIR) && \
	kubectl delete -f knative-webshop.yaml && \
	helm uninstall unicorn-valkey

# Clean up EKS and delete Istio before to clean up the created NLB
clean-eks:
	@echo "Cleaning up EKS cluster..."
	aws eks update-kubeconfig --region $(REGION) --name serverless-wasm && \
	cd $(KUBERNETES_DIR) && \
	kubectl delete -f https://github.com/knative/net-istio/releases/download/knative-v1.15.1/net-istio.yaml && \
	kubectl delete -f istio.yaml && \
	cd ../$(TERRAFORM_DIR) && \
	export AMD64_AMI_ID=$$(aws ec2 describe-images --region $(REGION) --filters "Name=tag:Environment,Values=serverless-wasm" "Name=architecture,Values=x86_64" --query 'Images[*].ImageId' --output text) && \
	export ARM64_AMI_ID=$$(aws ec2 describe-images --region $(REGION) --filters "Name=tag:Environment,Values=serverless-wasm" "Name=architecture,Values=arm64" --query 'Images[*].ImageId' --output text) && \
	terraform destroy -auto-approve -var="region=$(REGION)" -var="custom_ami_id_amd64=$$AMD64_AMI_ID" -var="custom_ami_id_arm64=$$ARM64_AMI_ID"

# Clean up AMIs
clean-amis:
	@echo "Cleaning up AMIs with tags: $(PKR_VAR_tags) in region $(REGION)..."
	@AMI_IDS=$$(aws ec2 describe-images \
		--region $(REGION) \
		--owners self \
		--filters "Name=tag:Environment,Values=serverless-wasm" \
		--query 'Images[*].ImageId' \
		--output text); \
	if [ -n "$$AMI_IDS" ]; then \
		echo "Deregistering AMIs: $$AMI_IDS"; \
		for AMI_ID in $$AMI_IDS; do \
			aws ec2 deregister-image --region $(REGION) --image-id $$AMI_ID; \
			echo "Deregistered AMI: $$AMI_ID"; \
		done; \
	else \
		echo "No AMIs found with the specified tags."; \
	fi

# Clean up Snapshots
clean-snapshots:
	@echo "Cleaning up Snapshots with tags: $(PKR_VAR_snapshot_tags) in region $(REGION)..."
	@SNAPSHOT_IDS=$$(aws ec2 describe-snapshots \
		--region $(REGION) \
		--owner-ids self \
		--filters "Name=tag:Environment,Values=serverless-wasm" \
		--query 'Snapshots[*].SnapshotId' \
		--output text); \
	if [ -n "$$SNAPSHOT_IDS" ]; then \
		echo "Deleting Snapshots: $$SNAPSHOT_IDS"; \
		for SNAPSHOT_ID in $$SNAPSHOT_IDS; do \
			aws ec2 delete-snapshot --region $(REGION) --snapshot-id $$SNAPSHOT_ID; \
			echo "Deleted Snapshot: $$SNAPSHOT_ID"; \
		done; \
	else \
		echo "No Snapshots found with the specified tags."; \
	fi

# Clean up (now includes AMI and Snapshot cleanup)
clean: clean-webshop clean-eks clean-amis clean-snapshots
	@echo "Cleanup complete"

.PHONY: all build-amis build-eks build-knative build-webshop clean-webshop clean-eks clean-amis clean-snapshots
