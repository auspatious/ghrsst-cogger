init:
	terraform -chdir=terraform init

plan:
	terraform -chdir=terraform plan \
		-var-file=prod.tfvars

apply:
	terraform -chdir=terraform apply \
		-var-file=prod.tfvars

destroy:
	terraform -chdir=terraform destroy \
		-var-file=prod.tfvars

# Run with `make build VERSION=0.1.0`
build:
	docker build -t ghrsst-cogger:latest .
	docker tag ghrsst-cogger:latest auspatious/ghrsst-cogger:$(VERSION)

push:
	docker push auspatious/ghrsst-cogger:$(VERSION)

data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc:
	echo "Go get the file!"

run-local: data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc
	python3 ghrsst/cogger.py \
		--date "2023-11-06" \
		--input-location data \
		--output-location data/output \
		--overwrite

run-s3: data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc
	python3 ghrsst/cogger.py \
		--date "2023-11-06" \
		--input-location data \
		--output-location s3://files.auspatious.com/ghrsst_test_2024 \
		--overwrite

run-dl: data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc
	python3 ghrsst/cogger.py \
		--date "2024-04-12" \
		--input-location "JPL" \
		--output-location data/output \
		--overwrite

run-dl-cache: data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc
	python3 ghrsst/cogger.py \
		--date "2024-04-12" \
		--input-location "JPL" \
		--output-location data/output \
		--overwrite \
		--cache-local
