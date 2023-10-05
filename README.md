# zprun

Zig Procfile Runner

Designed for use inside containers. Small, fast, static.

## Usage

    zprun web

Loads the default procfile, which is the file named Procfile in the
current directory. Finds the label `web` in the file and runs the command,
replacing itself with that process.

    zprun -f OtherProcfile web

Runs the `web` labelled command from the procfile named `OtherProcfile`
in the current directory.

## What is a Procfile?

https://devcenter.heroku.com/articles/procfile

## Notes

Commands from the procfile are NOT interpreted via a shell. If you want
that behavior, specify it in the procfile command explicitly like this:

    web: /bin/bash -c "/usr/local/bin/appserver > /var/log/file.log 2>&1"

## Alternatives

Many alternatives exist, here is some of them. I have not tested all of these.

- https://github.com/ddollar/foreman
- https://github.com/ddollar/forego
- https://github.com/bytegust/spm
- https://github.com/fgrosse/prox
