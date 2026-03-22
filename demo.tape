# OS Kickstart TUI Demo
# Recorded with VHS: https://github.com/charmbracelet/vhs

Output demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 1100
Set Height 420
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 50ms
Set Framerate 24

Type "./kickstart"
Sleep 400ms
Enter

# Wait for menu + update checks
Sleep 4s

# Scroll all the way down to bottom (26 items + separators)
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms
Down
Sleep 250ms

Sleep 1s

# Scroll back up to top
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms
Up
Sleep 150ms

Sleep 500ms

# Select GNOME Optimize
Space
Sleep 300ms

# Select Nautilus
Down
Space
Sleep 300ms

# Skip down to Shell section
Down
Sleep 200ms
Down
Sleep 200ms
Down
Sleep 200ms
Down
Sleep 200ms
Down
Sleep 200ms
Down
Sleep 200ms
Down
Sleep 200ms
Down
Sleep 200ms

# Select fzf
Space
Sleep 300ms

Sleep 500ms

# Demo filter search
Type "/"
Sleep 300ms
Type "docker"
Sleep 1s
Escape
Sleep 500ms

# Select all with ctrl+a
Ctrl+a
Sleep 1s

# Confirm
Enter
Sleep 1s

# Pick Install mode
Enter
Sleep 1s

# Cancel at confirm screen
Escape

Sleep 1s

# Quit
Type "q"
Sleep 500ms
