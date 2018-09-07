OCI (Open Container Initiative)
================================================================================
Looking into the OCI spec to see if it will work for my OS.

A container is a self-contained chunk of software.  I think this may be how
I want to install packages on my OS.

Each container must have a file called `config.json` which contains information
about the container.

### config.json

https://github.com/opencontainers/runtime-spec/blob/master/config.md

Contains "standard operations" against the container, i.e.
* processes to run
* environment variables to inject
* sandboxing features to use

