# VIM

## Normal Mode
- `x`: delete the char
- `A`: append text to end of line
- `$`: move cursor to end of line
- `g_`: move cursor to last non whitespace char
- `dd`: delete an entire line
- `5dd`: delete 5 lines below the cursor

## Insert Mode
Press `i` to enter

## Visual Mode
- `V`: select an entire line
- `Vd`: delete an entire line

## Ex Mode
Press `:` to enter. Range followed by command.
- `:15,18d`: delete lines 15, 16, 17, 18
- `:g/console.log/d`: delete all lines containing "console.log"