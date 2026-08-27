#!/usr/bin/env bash

set -euo pipefail

VERSION=${VERSION:-1.1.3-selfheal.1}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR="$SCRIPT_DIR/source"
STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT

for arch in amd64 arm64 s390x; do
  output_dir="$STAGE_DIR/$arch"
  mkdir -p "$output_dir"
  (
    cd "$SOURCE_DIR"
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build \
      -buildvcs=false \
      -trimpath \
      -ldflags "-s -w -X main.version=$VERSION" \
      -o "$output_dir/wireproxy" \
      ./cmd/wireproxy
  )
  python3 - "$output_dir/wireproxy" "$SCRIPT_DIR/wireproxy_linux_${arch}.tar.gz" <<'PY'
import gzip
import os
import sys
import tarfile

binary, archive = sys.argv[1:]
with open(archive, "wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            info = tarfile.TarInfo("wireproxy")
            info.size = os.path.getsize(binary)
            info.mode = 0o755
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mtime = 0
            with open(binary, "rb") as source:
                tar.addfile(info, source)
PY
done

(
  cd "$SCRIPT_DIR"
  shasum -a 256 wireproxy_linux_*.tar.gz > SHA256SUMS
)
