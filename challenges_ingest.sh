#!/bin/bash

USER=${SUDO_USER:-$USER}
WORKING_FOLDER="/home/$USER"
CTF_REPO="PolyPwnCTF-2025"
REPO_PATH="$WORKING_FOLDER/$CTF_REPO"

CHALLENGE_PATH="$REPO_PATH/challenges"
BUILD_DOCKERS="false"

for category in "$CHALLENGE_PATH"/*; do
  if [ -d "$category" ]; then
    for challenge in "$category"/*; do
      if [ -d "$challenge" ]; then
        challenge_name=$(basename "$challenge")
        challenge_yml="$category/$challenge_name/challenge.yml"

        if grep -q '^type: docker$' "$challenge_yml"; then
          docker_image=$(grep '^  docker_image:' "$challenge_yml" | sed -E 's/^  docker_image: "([^"]+):[^"]+"/\1/')
          echo "Building Challenge: $challenge_name, Docker Image: $docker_image"
          if [ "$BUILD_DOCKERS" = "true" ]; then
            $(cd "$category/$challenge_name" && docker build . -t "$docker_image" -f "$category/$challenge_name/Dockerfile")
          else 
            echo "docker build . -t $docker_image -f $category/$challenge_name/Dockerfile"
          fi
        fi
      fi
    done
  fi
done

# Prompt the user to continue
read -p "All Docker images have been built. Add them to the Docker Plugin directly in CTFd, then press Enter to continue with ingesting challenges..."

# Step 2: Ingest all challenges
for category in "$CHALLENGE_PATH"/*; do
  if [ -d "$category" ]; then
    for challenge in "$category"/*; do
      if [ -d "$challenge" ]; then
        challenge_name=$(basename "$challenge")
        echo "Installing $challenge_name..."
        echo "ctf challenge install '$category/$challenge_name'"
        ctf challenge install "$category/$challenge_name"
      fi
    done
  fi
done

echo "All challenges have been ingested."
