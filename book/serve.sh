#!/bin/sh
# Live-reloading local book at http://localhost:8000 (Ctrl+C to stop).
# Run from anywhere: sh book/serve.sh
root=$(cd "$(dirname "$0")/.." && pwd)
podman run --rm -it -p 8000:8000 \
  -v "${root}:/docs:ro" \
  -v "${root}/book/mkdocs.yml:/mkdocs.yml:ro" \
  docker.io/squidfunk/mkdocs-material serve -f /mkdocs.yml -a 0.0.0.0:8000
