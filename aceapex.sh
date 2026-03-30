#!/bin/bash
BIN="$(dirname $0)/aceapex"
case "$1" in
  compress)   $BIN c --in "$2" --out "${2}.aet" --threads ${3:-8} ;;
  decompress) $BIN d --in "$2" --out "${2%.aet}" ;;
  test)       $BIN t --in "$2" --threads ${3:-8} ;;
  *)
    echo "ACEAPEX — lossless compression"
    echo ""
    echo "Usage:"
    echo "  aceapex compress   <file> [threads]"
    echo "  aceapex decompress <file.aet>"
    echo "  aceapex test       <file> [threads]"
    ;;
esac
