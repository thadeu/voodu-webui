.PHONY: build clean test vet

# Binary output goes to `dist/poller` (gem-root), NOT `src/poller`,
# because `src/poller/` is the Go package directory — same name would
# put the binary inside that dir and confuse Poller.binary_path lookups.
# `bin/poller` is also taken — that's the Ruby binstub template the
# Railtie copies into the Rails app's bin/ on first boot.
build:
	cd src && mkdir -p ../dist && go build -o ../dist/poller .

test:
	cd src && go test ./...

vet:
	cd src && go vet ./...

clean:
	rm -f dist/poller
