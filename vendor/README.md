# Vendored runtime dependencies

These files are retained in this repository so installation does not depend on the original fscarmen repositories remaining online.

| Path | Upstream snapshot | License | Purpose |
| --- | --- | --- | --- |
| `warp_unlock/` | `fscarmen/warp_unlock` commit `62b408f08682d1e5776e9ad955ba1e7ca71fefca` | GPLv3, included alongside the source | Optional WARP IP/unlock helper called by the menus |
| `openresolv/` | openresolv `v3.13.2` | BSD 2-Clause, included alongside the source | `resolvconf` fallback used on CentOS Stream 9 |

The repository also retains the upstream snapshots already present in `wireguard-go/`, `wireproxy/`, `warp-go/`, `wgcf/`, and `endpoint/`. Third-party services such as Cloudflare APIs and operating-system package repositories are not vendored.

The legacy Docker installer builds `docker/wgcf/Dockerfile` locally and no longer requires the original `fscarmen/wgcf` image.
