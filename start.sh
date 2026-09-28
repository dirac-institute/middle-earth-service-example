#!/bin/bash
set -e

gunicorn --bind 127.0.0.1:8000 --workers 2 --chdir /srv/app server:app &

exec httpd-foreground
