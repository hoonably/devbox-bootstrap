# Load ~/.bashrc for interactive login shells such as SSH.
if [[ $- == *i* ]] && [ -r "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
