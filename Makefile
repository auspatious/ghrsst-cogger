init:
	terraform -chdir=terraform init

plan:
	terraform -chdir=terraform plan \
		-var-file=test.tfvars

apply:
	terraform -chdir=terraform apply \
		-var-file=test.tfvars

data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc:
	echo "Go get the file!"

run-local: data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc
	python3 ghrsst_cogger.py \
		--date "2023-11-06" \
		--input-location data \
		--output-location data/output \
