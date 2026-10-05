# Third-party runtime

CodexBridge's Swift code and scripts are original MIT-licensed wrapper code. They do not link to Mihomo or embed Mihomo source code.

The installer downloads an independent executable from the official [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) repository, pinned to [v1.19.32](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.32). Its compressed asset SHA256 is pinned separately for Apple Silicon and Intel in `scripts/fetch-core.sh` and verified before extraction.

Mihomo is licensed under [GPL-3.0](https://github.com/MetaCubeX/mihomo/blob/v1.19.32/LICENSE). Its corresponding source code is available at the tagged upstream repository. The downloaded executable and archives are excluded from this Git repository.

If distributing Mihomo binaries separately, include the applicable upstream license and corresponding source as required by that license; the wrapper's MIT license does not replace the core's license.
