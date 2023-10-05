build:
	zig build-exe src/main.zig -O ReleaseSafe --name zigrun

build-debug:
	zig build-exe src/main.zig --name zigrun
	
build-small:
	zig build-exe src/main.zig -O ReleaseSmall --name zigrun

build-fast:
	zig build-exe src/main.zig -O ReleaseFast --name zigrun

test: zig-test integration-test

zig-test:
	zig test src/main.zig

integration-test: integration-test-build
	./tests/run-integration.sh integration-test-build

integration-test-build:
	zig build-exe src/main.zig -O ReleaseSafe --name integration-test-build

