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

update-readme:
	AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED \
		aws s3 cp readme_for_source_coop.md s3://ausantarctic/ghrsst-mur-v2/README.md

count-stac:
	aws s3 ls --recursive s3://ausantarctic/ghrsst-mur-v2/ | grep '\.json$' | wc -

# Run with `make build VERSION=0.1.0`
build:
	docker buildx build --platform linux/amd64 -t ghrsst-cogger:latest .
	docker tag ghrsst-cogger:latest 381491825451.dkr.ecr.us-west-2.amazonaws.com/ghrsst-cogger:latest
	docker tag ghrsst-cogger:latest 381491825451.dkr.ecr.us-west-2.amazonaws.com/ghrsst-cogger:$(VERSION)

push:
	docker push 381491825451.dkr.ecr.us-west-2.amazonaws.com/ghrsst-cogger:latest
	docker push 381491825451.dkr.ecr.us-west-2.amazonaws.com/ghrsst-cogger:$(VERSION)

data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc:
	echo "Go get the file!"

run-source-coop:
	python3 ghrsst/cogger.py \
		--date "2025-01-01" \
		--input-location data \
		--output-location "s3://ausantarctic/ghrsst-mur-v2/" \
		--overwrite

run-local:
	python3 ghrsst/cogger.py \
		--date "2025-02-02" \
		--input-location data \
		--output-location data/output \
		--overwrite

run-s3: data/20231106090000-JPL-L4_GHRSST-SSTfnd-MUR-GLOB-v02.0-fv04.1.nc
	python3 ghrsst/cogger.py \
		--date "2025-01-01" \
		--input-location data \
		--output-location s3://idea-ghrsst-testing/ghrsst-mur-v2/ \
		--cache-local \
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

