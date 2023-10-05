build:
	zig build-exe src/main.zig -O ReleaseSafe --name zprun

build-debug:
	zig build-exe src/main.zig --name zprun
	
build-small:
	zig build-exe src/main.zig -O ReleaseSmall --name zprun

build-fast:
	zig build-exe src/main.zig -O ReleaseFast --name zprun

build-linux-static:
	zig build-exe src/main.zig -target x86_64-linux-musl --name zprun -O ReleaseSafe

test: zig-test integration-test

zig-test:
	zig test src/main.zig

integration-test: integration-test-build
	./tests/run-integration.sh integration-test-build

integration-test-build:
	zig build-exe src/main.zig -O ReleaseSafe --name integration-test-build

