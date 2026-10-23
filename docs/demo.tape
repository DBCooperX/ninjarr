# Re-records docs/demo.gif with VHS (https://github.com/charmbracelet/vhs):
#   brew install vhs
#   vhs docs/demo.tape          (run from the repo root)
#   gifsicle -O3 --lossy=12 docs/demo.gif -o docs/demo.gif   (optional: a third of the size)
#
# Plays docs/demo.sh: a replay of a first ./bootstrap.sh run that uses the real lib/ui.sh
# (banner, spinner, prompts), with typed answers and canned wiring output. No Docker, no network.

Output docs/demo.gif

Require bash

Set Shell "bash"
Set FontFamily "Menlo"
Set FontSize 14
Set Width 960
Set Height 700
Set Padding 20
Set Theme "Dracula"
Set TypingSpeed 60ms

# Hidden setup: a temp folder whose ./bootstrap.sh is a link to docs/demo.sh, so the recording
# shows the real command.
Hide
Type `cd "$(mktemp -d)" && ln -s "$OLDPWD/docs/demo.sh" bootstrap.sh && clear`
Enter
Sleep 300ms
Show

Type "./bootstrap.sh"
Sleep 500ms
Enter

Sleep 36s
