.PHONY: help test policy fmt validate scan site serve plan-aws plan-azure

help:          ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

test:          ## Python unit tests
	pytest -q

policy:        ## OPA policy unit tests
	opa test policies/opa -v

fmt:           ## Format Terraform
	terraform fmt -recursive infra

validate:      ## terraform validate every stack (no backend)
	@for d in infra/aws infra/azure infra/bootstrap/aws infra/bootstrap/azure; do \
	  terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; done

scan:          ## Checkov
	checkov -d infra --config-file .checkov.yaml

site:          ## Build the site for local preview
	python scripts/build.py web --served-by local

serve: site    ## Preview on http://localhost:8080
	python -m http.server 8080 --directory dist/web

plan-aws:      ## Plan AWS + Conftest (needs infra/aws/backend.hcl, terraform.tfvars)
	scripts/plan_and_check.sh aws $(PWD)/infra/aws/backend.hcl -var-file=terraform.tfvars

plan-azure:    ## Plan Azure + Conftest (needs infra/azure/backend.hcl, terraform.tfvars)
	scripts/plan_and_check.sh azure $(PWD)/infra/azure/backend.hcl -var-file=terraform.tfvars
