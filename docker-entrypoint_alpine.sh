#!/bin/sh
# The Alpine image renders through surfaceless EGL, so unlike the Ubuntu
# entrypoint there is no Xvfb to start, no DISPLAY to export and no X lock file
# to clear -- which also means no bash process substitution, so plain sh is
# enough. This is the same shape as docker-entrypoint_light.sh.
if ! which -- "${1}"; then
  # first arg is not an executable
  exec node /usr/src/app/ "$@"
fi

exec "$@"
