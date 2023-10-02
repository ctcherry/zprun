build:
	zig build-exe src/main.zig -O ReleaseSafe --name zigrun
	
build-small:
	zig build-exe src/main.zig -O ReleaseSmall --name zigrun

build-fast:
	zig build-exe src/main.zig -O ReleaseFast --name zigrun
