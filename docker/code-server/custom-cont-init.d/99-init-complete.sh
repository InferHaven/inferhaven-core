#!/bin/bash
# Drops the boot-mode sentinel after every other custom-cont-init.d script has
# run. Earlier scripts (10–50) read this sentinel to decide whether to log a
# "cold boot" or "warm boot" marker. By creating it here (last), the whole
# first-boot pass reports consistently — every script sees the same value.
mkdir -p /config/.haven
chown abc:abc /config/.haven 2>/dev/null || true
touch /config/.haven/.code-server-initialized
