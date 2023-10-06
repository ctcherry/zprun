#!/bin/bash

bin=./$1

tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'mytmpdir')

cat <<EOF > $tmpdir/Procfile1
label0: ls -la
label1: /bin/bash -c "echo hello"
EOF

test() {
  name=$1
  label=$2
  match=$3
  echo -n "Test $name: "
  if $bin -f $tmpdir/Procfile1 "$label" 2>&1 | grep -q "$match"; then
    echo "passed"
  else
    echo "failed"
  fi
}

test "basic" "label0" "build.zig"
test "error missing label" "missing" "Unable to find label"

echo -n "Test error when no param for -f: "
if $bin "label0" -f 2>&1 | grep -q "Missing argument for -f"; then
  echo "passed"
else
  echo "failed"
fi

echo -n "Test error when unknown param -z: "
if $bin "label0" -z 2>&1 | grep -q "Unknown argument '-z'"; then
  echo "passed"
else
  echo "failed"
fi

rm -rf $tmpdir
exit 0
