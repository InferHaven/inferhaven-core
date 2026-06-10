#!/bin/bash
###############################################################################
# InferHaven system monitor — standalone btop launcher
#
# Formerly the nested-tmux popup handler; that logic now lives entirely in
# inferhaven-right-popup.sh. This script remains for direct invocation
# (e.g. from a custom keybinding or shell alias).
###############################################################################

exec btop
