.PHONY: build test run smoke
build:
	bash scripts/build.sh
test:
	GOWORK=$(CURDIR)/.build/go.work go test -race ./cmd/lab
	forge test --root contracts
	python3 -m unittest discover -s tests -v
run:
	bash scripts/run.sh
smoke:
	ENCLAVE=avax-lab-smoke bash scripts/run.sh examples/default.yml
