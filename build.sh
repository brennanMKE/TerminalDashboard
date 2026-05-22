#!/bin/bash
set -euo pipefail

ACTIONS=("${@:-build}")

for ACTION in "${ACTIONS[@]}"; do
  case "$ACTION" in
    clean)
      swift package clean
      ;;
    build)
      swift build
      ;;
    run)
      swift run tuidash
      ;;
    *)
      echo "Usage: $0 {clean|build|run}..."
      exit 1
      ;;
  esac
done
