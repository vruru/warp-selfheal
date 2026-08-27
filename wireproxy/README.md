# Patched WireProxy

This directory contains reproducible Linux builds and the complete source used
to produce them. The base is upstream WireProxy v1.1.3, commit
`31a9a34498267d7fb8aeff05aba79d929b15eb39`, licensed under ISC.

The `selfheal.1` patch fixes an unbounded SOCKS CONNECT lifetime: after one TCP
direction ended, the old implementation could wait forever for the opposite
direction and retain goroutines, netstack state, and 256 KiB copy buffers. The
patched relay uses 32 KiB buffers and an inactivity-based drain window. Active
half-closed responses refresh the window and continue normally; only a silent
orphan is reclaimed after two minutes.

The regression tests are in [`source/socks_relay_test.go`](source/socks_relay_test.go).
Build all bundled Linux archives with:

```bash
VERSION=1.1.3-selfheal.1 ./wireproxy/build.sh
```

Archive hashes are recorded in [`SHA256SUMS`](SHA256SUMS).
