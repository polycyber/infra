#!/bin/bash

USER=${SUDO_USER:-$USER}
WORKING_FOLDER="/home/$USER"
CTF_REPO="PolyPwnCTF-2025"
REPO_PATH="$WORKING_FOLDER/$CTF_REPO"

CHALLENGE_PATH="$REPO_PATH/challenges"

for category in "$CHALLENGE_PATH"/*; do
  if [ -d "$category" ]; then
    for challenge in "$category"/*; do
      if [ -d "$challenge" ]; then
        challenge_name=$(basename "$challenge")
        ctf challenge install "$category/$challenge_name"
      fi
    done
  fi
done
