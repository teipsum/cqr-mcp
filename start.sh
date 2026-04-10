#!/bin/bash
cd /Users/michaelcram/git/teipsum/cqr-mcp
source ~/.cargo/env
# -noshell prevents BEAM from starting its interactive shell / user_drv,
# which would otherwise intercept stdin and break the MCP stdio transport.
# Do NOT add -noinput — that would close stdin entirely.
export ERL_FLAGS="-noshell"
exec mix run --no-halt
