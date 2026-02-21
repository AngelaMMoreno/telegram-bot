#!/bin/sh
# Start the web server in the background
python web.py &

# Start the bot in the foreground
python bot.py
