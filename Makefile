init:
	terraform -chdir=terraform init

plan:
	terraform -chdir=terraform plan \
		-var-file=test.tfvars

apply:
	terraform -chdir=terraform apply \
		-var-file=test.tfvars
