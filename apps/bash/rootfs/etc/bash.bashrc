# Read by every interactive bash; login shells (ssh) get here via /etc/profile.

[ -z "$PS1" ] && return

# user@host:dir, then # for root or $ for anyone else. The host is the
# hostname from the ip= boot parameter (GUEST_NAME), minlin by default.
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '

# A serial console can't report its window size, so the guest sees 0x0 and
# readline assumes 80 columns. A command longer than that returns to column 0
# and is drawn over the prompt and its own start, whatever the real width.
# Without line editing the kernel echoes input as it arrives and never
# returns to column 0. ssh sessions have a size, so they keep line editing.
# The size set here is only for programs such as ls; stty size prints
# nothing when there is none.
if [ -z "$(stty size 2>/dev/null)" ]; then
    stty rows 24 cols 160
    set +o emacs +o vi
fi
