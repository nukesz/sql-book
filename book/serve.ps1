# Live-reloading local book at http://localhost:8000 (Ctrl+C to stop).
# Run from anywhere: pwsh book/serve.ps1
$root = Split-Path -Parent $PSScriptRoot
podman run --rm -it -p 8000:8000 `
  -v "${root}:/docs:ro" `
  -v "${root}/book/mkdocs.yml:/mkdocs.yml:ro" `
  docker.io/squidfunk/mkdocs-material serve -f /mkdocs.yml -a 0.0.0.0:8000
