.PHONY: build run lint test release-local clean

build:
	go build -ldflags "-s -w" -o kickstart .

run:
	go run .

lint:
	golangci-lint run ./...

test:
	go test ./...

release-local:
	goreleaser release --snapshot --clean

clean:
	rm -f kickstart
