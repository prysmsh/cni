BINARY   := prysm-cni
IMAGE    := ghcr.io/prysmsh/cni
VERSION  ?= v0.1.0

.PHONY: build test clean docker lint

build:
	CGO_ENABLED=0 go build -o $(BINARY) ./cmd/prysm-cni

test:
	go test -v ./...

clean:
	rm -f $(BINARY)
	go clean -testcache

docker:
	docker build -t $(IMAGE):$(VERSION) .

lint:
	go vet ./...
	golangci-lint run ./...
