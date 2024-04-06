label0: ls -la
label1: /bin/bash -c "echo hello"
label2: /bin/bash -c "echo 'ok'"
label3 : test3
date: /usr/bin/date
true: /usr/bin/true
aaa: /bin/bash -c "while true; do printf 'AAA '; date; >&2 date; date; sleep 3; done;"
bbb: /bin/bash -c "while true; do printf 'BBB '; date; sleep 5; done;"
ccc: /bin/bash -c "while true; do printf 'CCC '; date; sleep 7; done;"
ddd: /bin/bash -c "while true; do printf 'CCC '; date; sleep 0.25; done;"
stress1: /bin/bash -c "tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 4096"
stress2: /bin/bash -c "tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 4095; false"
stress3: /bin/bash -c "tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 4097"
