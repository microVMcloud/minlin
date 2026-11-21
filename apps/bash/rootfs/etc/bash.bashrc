# Read by every interactive bash; login shells (ssh) get here via /etc/profile.

[ -z "$PS1" ] && return

# user@host:dir, then # for root or $ for anyone else. The host is the
# hostname from the ip= boot parameter (GUEST_NAME), minlin by default.
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# A serial console can't report its window size, so the guest sees 0x0 and
# readline assumes 80 columns. In a wider window, a line longer than that
# returns to column 0 and is drawn over the prompt and its own start. resize
# asks the terminal instead: it moves the cursor to the far corner, requests
# the cursor position (ESC[6n), and restores it. Run it again after resizing
# the window. ssh sessions already have a size, so it only runs when there is
# none (busybox's stty size then prints nothing).
resize() {
    local esc rows cols
    # Echo off first: the reply can arrive before read would turn it off.
    stty -echo
    printf '\e7\e[999;999H\e[6n\e8' > /dev/tty
    IFS='[;' read -r -d R -t 1 esc rows cols < /dev/tty
    stty echo
    [[ $rows =~ ^[0-9]+$ && $cols =~ ^[0-9]+$ ]] || return 1
    stty rows "$rows" cols "$cols"
}
case "$(stty size 2>/dev/null)" in ""|"0 0") resize ;; esac
