.PHONY: build clean test vet

build:
	cd src && go build -o log-poller .

test:
	cd src && go test ./...

vet:
	cd src && go vet ./...

clean:
	rm -f src/log-poller
