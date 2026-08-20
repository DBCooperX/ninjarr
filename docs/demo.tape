# Builds docs/demo.gif for the README. Requires VHS (https://github.com/charmbracelet/vhs):
#   brew install vhs
#   vhs docs/demo.tape
#
# Plays back demo.sh — a canned, offline replay of bootstrap.sh's real output style (same
# palette, same step/ok chrome) — not a live run against real containers. Recorded as
# "./bootstrap.sh" for an authentic look; the temp copy is cleaned up after.

Output docs/demo.gif

Require bash

Set Shell "bash"
Set FontFamily "Menlo"
Set FontSize 15
Set Width 860
Set Height 620
Set Padding 24
Set Theme "Dracula"
Set TypingSpeed 60ms

Hide
Type "cd docs && cp demo.sh bootstrap.sh && clear"
Enter
Sleep 300ms
Show

Type "./bootstrap.sh"
Sleep 500ms
Enter

Sleep 13s

Hide
Type "rm -f bootstrap.sh"
Enter
