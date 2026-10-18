# App Review service lifecycle

A review-only Ollama endpoint runs on the existing **Ultron** host. It is not compiled into MobileLlama and is not offered to public app users.

- Existing `ollama` Docker service hosts the newly downloaded `qwen2.5:3b` model (about 1.9 GB on disk).
- Added `mobilellama-review-gateway` (official Caddy image) and `mobilellama-review-tunnel` (official Cloudflare image) containers, both with `unless-stopped` restart policy. No local container VM was installed or started.
- Caddy listens only on host loopback port 18134. A random private URL prefix admits `/api/version`, `/api/tags`, `/api/show`, and `/api/chat`; management endpoints are unavailable. Access logging is not enabled.
- Cloudflare provides HTTPS for the review connection. Its Quick Tunnel URL is temporary and changes if the tunnel process is recreated. It has no uptime guarantee. The running tunnel must remain available during review; if it restarts with a new hostname, update the private App Review notes. [Cloudflare limitations](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/).
- The private URL was entered only into App Review notes and private local files. Do not put it in public documentation or store copy.

Local private files: `~/.local/share/mobilellama-app-review/review-url`, `endpoint`, and `api-key` on the Mac; `~/.local/share/mobilellama-app-review/` on Ultron contains the gateway configuration and credential. These files are outside the repository. Apple review notes also retain the complete connection instructions.

Verification used the actual application `OllamaClient`, not a protocol fixture. Version/model/capability requests and a complete streamed answer succeeded; the response contained 553 chunks. The evidence in the package omits the private URL.

Keep these two review containers and the model through Apple's review. Once review no longer needs them, remove only `mobilellama-review-gateway` and `mobilellama-review-tunnel`, remove the review-specific directory, and remove `qwen2.5:3b` if it has not since been adopted for another purpose. Preserve the pre-existing Ollama, Open WebUI, and other services. The earlier trial `qwen3:4b` model was removed.
