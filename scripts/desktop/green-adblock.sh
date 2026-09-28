#!/bin/bash
# Start Spotify with the spotify-adblock library preloaded
# got green client from: https://www.spotify.com/us/download/linux/
# https://github.com/abba23/spotify-adblock

LD_PRELOAD=/usr/local/lib/spotify-adblock.so spotify
