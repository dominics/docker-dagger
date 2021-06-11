Docker compose files, for
# dagger


## Installation

- Create a system user
- Copy `.env.example` to `.env` and modify
  - Particularly, replace the `PUID` and `PGID` variables with the UID and GID of the user
- Change to the `ssl/` directory, and run `./generate`, which will create `minica.pem` and other files
- Set up docker-nvidia for Plex 
