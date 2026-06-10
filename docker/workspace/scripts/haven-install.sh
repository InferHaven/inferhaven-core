#!/bin/bash
###############################################################################
# haven-install — compatibility shim
#
# This command has been absorbed into 'haven apt'. This shim is kept so that
# existing scripts and muscle memory continue to work.
#
# Preferred usage going forward:
#   haven apt install <package> [package2 ...]
#   haven apt remove <package>
#   haven apt list
#   haven apt upgrade
###############################################################################
case "${1:-}" in
  --list)    exec haven apt list ;;
  --remove)  shift; exec haven apt remove "$@" ;;
  --upgrade) exec haven apt upgrade ;;
  --help|-h) exec haven apt help ;;
  -*)        echo "Unknown option: $1. Use 'haven apt' instead." >&2; exit 1 ;;
  *)         exec haven apt install "$@" ;;
esac
