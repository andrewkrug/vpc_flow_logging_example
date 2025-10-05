.PHONY: help validate deploy-cloudwatch deploy-s3 deploy-s3-production deploy-s3-security delete clean

# Variables
STACK_NAME ?= vpc-flow-logs
VPC_ID ?=
REGION ?= us-east-1
RETENTION_DAYS ?= 14
TRAFFIC_TYPE ?= ALL
BUCKET_NAME ?=
LIFECYCLE_ENABLED ?= Yes
GLACIER_TRANSITION_DAYS ?= 30
GLACIER_RETENTION_DAYS ?= 365
VERSIONING_ENABLED ?= Yes
OBJECT_LOCK ?= No

help:
	@echo "VPC Flow Logs Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  validate              - Validate all CloudFormation templates"
	@echo "  deploy-cloudwatch     - Deploy VPC Flow Logs to CloudWatch"
	@echo "  deploy-s3            - Deploy VPC Flow Logs to S3 (create new bucket)"
	@echo "  deploy-s3-existing   - Deploy VPC Flow Logs to existing S3 bucket"
	@echo "  deploy-s3-production - Deploy production account S3 bucket"
	@echo "  deploy-s3-security   - Deploy security tools S3 bucket"
	@echo "  delete               - Delete the CloudFormation stack"
	@echo "  clean                - Clean up local files"
	@echo ""
	@echo "Environment Variables:"
	@echo "  STACK_NAME           - CloudFormation stack name (default: vpc-flow-logs)"
	@echo "  VPC_ID               - VPC ID (required for deploy-cloudwatch and deploy-s3)"
	@echo "  REGION               - AWS region (default: us-east-1)"
	@echo "  RETENTION_DAYS       - Log retention in days (default: 14)"
	@echo "  TRAFFIC_TYPE         - ALL, ACCEPT, or REJECT (default: ALL)"
	@echo "  BUCKET_NAME          - S3 bucket name (optional, auto-generated if empty)"
	@echo "  LIFECYCLE_ENABLED    - Enable S3 lifecycle policy (default: Yes)"
	@echo "  GLACIER_TRANSITION_DAYS - Days before transitioning to Glacier (default: 30)"
	@echo "  GLACIER_RETENTION_DAYS  - Days to retain in Glacier (default: 365)"
	@echo "  VERSIONING_ENABLED   - Enable S3 versioning (default: Yes)"
	@echo "  OBJECT_LOCK          - Enable S3 object lock (default: No)"
	@echo ""
	@echo "Examples:"
	@echo "  make deploy-cloudwatch VPC_ID=vpc-123456 STACK_NAME=my-flow-logs"
	@echo "  make deploy-s3 VPC_ID=vpc-123456 BUCKET_NAME=my-flow-logs-bucket"
	@echo "  make delete STACK_NAME=my-flow-logs"

validate:
	@echo "Validating CloudFormation templates..."
	@aws cloudformation validate-template \
		--template-body file://vpc-flow-logs-to-cloudwatch/flow-logs.yml \
		--region $(REGION) > /dev/null && echo "✓ vpc-flow-logs-to-cloudwatch/flow-logs.yml is valid"
	@aws cloudformation validate-template \
		--template-body file://vpc-flow-logs-to-s3/flow-logs-s3.yml \
		--region $(REGION) > /dev/null && echo "✓ vpc-flow-logs-to-s3/flow-logs-s3.yml is valid"
	@aws cloudformation validate-template \
		--template-body file://vpc-flow-logs-to-s3/flow-logs-production-acct.yml \
		--region $(REGION) > /dev/null && echo "✓ vpc-flow-logs-to-s3/flow-logs-production-acct.yml is valid"
	@aws cloudformation validate-template \
		--template-body file://vpc-flow-logs-to-s3/flow-logs-security-tools.yml \
		--region $(REGION) > /dev/null && echo "✓ vpc-flow-logs-to-s3/flow-logs-security-tools.yml is valid"

deploy-cloudwatch:
ifndef VPC_ID
	$(error VPC_ID is required. Usage: make deploy-cloudwatch VPC_ID=vpc-123456)
endif
	@echo "Deploying VPC Flow Logs to CloudWatch..."
	@echo "Stack Name: $(STACK_NAME)"
	@echo "VPC ID: $(VPC_ID)"
	@echo "Region: $(REGION)"
	@echo "Retention: $(RETENTION_DAYS) days"
	@echo "Traffic Type: $(TRAFFIC_TYPE)"
	@echo ""
	aws cloudformation create-stack \
		--stack-name $(STACK_NAME) \
		--template-body file://vpc-flow-logs-to-cloudwatch/flow-logs.yml \
		--parameters \
			ParameterKey=VpcId,ParameterValue=$(VPC_ID) \
			ParameterKey=RetentionInDays,ParameterValue=$(RETENTION_DAYS) \
			ParameterKey=TrafficType,ParameterValue=$(TRAFFIC_TYPE) \
		--capabilities CAPABILITY_IAM \
		--region $(REGION)
	@echo ""
	@echo "Stack creation initiated. Monitor progress with:"
	@echo "  aws cloudformation wait stack-create-complete --stack-name $(STACK_NAME) --region $(REGION)"
	@echo "  aws cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(REGION)"

deploy-s3:
ifndef VPC_ID
	$(error VPC_ID is required. Usage: make deploy-s3 VPC_ID=vpc-123456)
endif
	@echo "Deploying VPC Flow Logs to S3 (new bucket)..."
	@echo "Stack Name: $(STACK_NAME)"
	@echo "VPC ID: $(VPC_ID)"
	@echo "Region: $(REGION)"
	@echo "Bucket Name: $(if $(BUCKET_NAME),$(BUCKET_NAME),auto-generated)"
	@echo "Traffic Type: $(TRAFFIC_TYPE)"
	@echo ""
	aws cloudformation create-stack \
		--stack-name $(STACK_NAME) \
		--template-body file://vpc-flow-logs-to-s3/flow-logs-s3.yml \
		--parameters \
			ParameterKey=VpcId,ParameterValue=$(VPC_ID) \
			ParameterKey=TrafficType,ParameterValue=$(TRAFFIC_TYPE) \
			ParameterKey=CreateBucket,ParameterValue=Yes \
			$(if $(BUCKET_NAME),ParameterKey=BucketName$(comma)ParameterValue=$(BUCKET_NAME)) \
			ParameterKey=EnableLifecyclePolicy,ParameterValue=$(LIFECYCLE_ENABLED) \
			ParameterKey=RetentionInDays,ParameterValue=$(RETENTION_DAYS) \
			ParameterKey=GlacierTransitionDays,ParameterValue=$(GLACIER_TRANSITION_DAYS) \
			ParameterKey=GlacierRetentionDays,ParameterValue=$(GLACIER_RETENTION_DAYS) \
			ParameterKey=EnableVersioning,ParameterValue=$(VERSIONING_ENABLED) \
			ParameterKey=ObjectLock,ParameterValue=$(OBJECT_LOCK) \
		--region $(REGION)
	@echo ""
	@echo "Stack creation initiated. Monitor progress with:"
	@echo "  aws cloudformation wait stack-create-complete --stack-name $(STACK_NAME) --region $(REGION)"
	@echo "  aws cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(REGION)"

deploy-s3-existing:
ifndef VPC_ID
	$(error VPC_ID is required. Usage: make deploy-s3-existing VPC_ID=vpc-123456 BUCKET_NAME=my-bucket)
endif
ifndef BUCKET_NAME
	$(error BUCKET_NAME is required. Usage: make deploy-s3-existing VPC_ID=vpc-123456 BUCKET_NAME=my-bucket)
endif
	@echo "Deploying VPC Flow Logs to existing S3 bucket..."
	@echo "Stack Name: $(STACK_NAME)"
	@echo "VPC ID: $(VPC_ID)"
	@echo "Bucket Name: $(BUCKET_NAME)"
	@echo "Region: $(REGION)"
	@echo "Traffic Type: $(TRAFFIC_TYPE)"
	@echo ""
	aws cloudformation create-stack \
		--stack-name $(STACK_NAME) \
		--template-body file://vpc-flow-logs-to-s3/flow-logs-s3.yml \
		--parameters \
			ParameterKey=VpcId,ParameterValue=$(VPC_ID) \
			ParameterKey=TrafficType,ParameterValue=$(TRAFFIC_TYPE) \
			ParameterKey=CreateBucket,ParameterValue=No \
			ParameterKey=BucketName,ParameterValue=$(BUCKET_NAME) \
		--region $(REGION)
	@echo ""
	@echo "Stack creation initiated. Monitor progress with:"
	@echo "  aws cloudformation wait stack-create-complete --stack-name $(STACK_NAME) --region $(REGION)"

deploy-s3-production:
ifndef BUCKET_NAME
	$(error BUCKET_NAME is required. Usage: make deploy-s3-production BUCKET_NAME=my-bucket)
endif
	@echo "Deploying production account S3 bucket..."
	@echo "Stack Name: $(STACK_NAME)-production"
	@echo "Bucket Name: $(BUCKET_NAME)"
	@echo "Region: $(REGION)"
	@echo ""
	aws cloudformation create-stack \
		--stack-name $(STACK_NAME)-production \
		--template-body file://vpc-flow-logs-to-s3/flow-logs-production-acct.yml \
		--parameters \
			ParameterKey=BucketName,ParameterValue=$(BUCKET_NAME) \
		--region $(REGION)
	@echo ""
	@echo "Stack creation initiated. Monitor progress with:"
	@echo "  aws cloudformation wait stack-create-complete --stack-name $(STACK_NAME)-production --region $(REGION)"

deploy-s3-security:
ifndef BUCKET_NAME
	$(error BUCKET_NAME is required. Usage: make deploy-s3-security BUCKET_NAME=my-bucket)
endif
	@echo "Deploying security tools S3 bucket..."
	@echo "Stack Name: $(STACK_NAME)-security"
	@echo "Bucket Name: $(BUCKET_NAME)"
	@echo "Region: $(REGION)"
	@echo ""
	aws cloudformation create-stack \
		--stack-name $(STACK_NAME)-security \
		--template-body file://vpc-flow-logs-to-s3/flow-logs-security-tools.yml \
		--parameters \
			ParameterKey=BucketName,ParameterValue=$(BUCKET_NAME) \
		--region $(REGION)
	@echo ""
	@echo "Stack creation initiated. Monitor progress with:"
	@echo "  aws cloudformation wait stack-create-complete --stack-name $(STACK_NAME)-security --region $(REGION)"

delete:
	@echo "Deleting CloudFormation stack: $(STACK_NAME)"
	@echo "Region: $(REGION)"
	@echo ""
	@read -p "Are you sure you want to delete this stack? [y/N] " -n 1 -r; \
	echo; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		aws cloudformation delete-stack \
			--stack-name $(STACK_NAME) \
			--region $(REGION); \
		echo "Stack deletion initiated. Monitor progress with:"; \
		echo "  aws cloudformation wait stack-delete-complete --stack-name $(STACK_NAME) --region $(REGION)"; \
	else \
		echo "Deletion cancelled."; \
	fi

clean:
	@echo "Cleaning up..."
	@find . -name ".DS_Store" -delete
	@echo "Done."
