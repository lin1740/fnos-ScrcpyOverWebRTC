# CloudPhone for fnOS

[中文](README.md) | **English**

Deploy the **CloudPhone (穿云投屏 / ScrcpyOverWebRTC)** server on fnOS with one click — view and control Android devices remotely from a browser, no extra client required.

This repository is a **third-party, unofficial packaging** of [ScrcpyOverWebRTC](https://github.com/hqw700/ScrcpyOverWebRTC) (by hqw700) for fnOS. It contains the FPK build scripts, container orchestration, unified-gateway integration, and install / upgrade / maintenance scripts (source directory: `cloudphone_all_<version>`).

---

## 1. Nature of the Application

1. This application (appname = `cloudphone`, display name "穿云投屏" / CloudPhone) is a **third-party, unofficial packaging** of the open-source project ScrcpyOverWebRTC (穿云投屏, <https://github.com/hqw700/ScrcpyOverWebRTC>, author hqw700) for fnOS. It is packaged and distributed independently by a community developer and has **no affiliation, authorization, or partnership** with fnOS official (Guangzhou Tieran Zhizao Technology Co., Ltd.) or with the upstream author.
2. This application **provides the server side only** (signaling + TURN relay + web management panel). It **does not include an Android emulator or any Android system image**, and it **does not modify any upstream code**. The controlled devices are the user's own Android phones / tablets / cloud phones.
3. The application itself is **completely free, open source, and non-commercial**. It charges no fees and does not profit through any of its components.
4. This application **bundles no upstream software body**. At runtime it only pulls the upstream public image `buutuu/scrcpy-over-webrtc` via Docker (pinned by digest to a verified version shipped with the package, so upstream `latest` changes cannot silently alter behavior; switch explicitly with `scripts/set_image.sh --upgrade`, follow latest with `--follow-latest`, roll back with `--pin <sha256:...>`). The signaling server, Agent, and web frontend inside that image are provided by upstream; their license terms, release cadence, and feature boundaries are governed by upstream releases.
5. Paid value-added services offered upstream, such as "device count authorization", are **third-party paid licenses from the upstream author**. Fees are collected directly by the upstream licensing provider and are unrelated to fnOS official and to this packager. **Not paying does not affect any basic functionality** such as screen mirroring, terminal, or file transfer.
6. A single package supports both x86_64 and ARM64; the matching image is selected automatically by device architecture, so there is no separate download.

> The application is reachable through the fnOS unified gateway (the App Center entry serves `/app/cloudphone`, with TLS terminated at the gateway), while LAN direct access is preserved (default `8443/TCP`, self-signed HTTPS).

---

## 2. Documentation

### 2.1 Detailed Usage Tutorial

**See the official upstream documentation: <https://webrtc-phone.com/docs/>**

Direct links to key chapters:

| Topic | Link |
| --- | --- |
| Documentation home | <https://webrtc-phone.com/docs/> |
| fnOS / NAS deployment | <https://webrtc-phone.com/docs/deploy-nas.html> |
| Device onboarding & Agent deployment (six methods) | <https://webrtc-phone.com/docs/agent-deploy.html> |
| Server configuration & ports | <https://webrtc-phone.com/docs/deploy-config.html> |
| Feature handbook (dashboard / batch control / sharing / terminal / files) | <https://webrtc-phone.com/docs/feature-dashboard.html> |
| Troubleshooting (timeouts, black screen, touch issues) | <https://webrtc-phone.com/docs/faq.html> |

**Upstream author's project: <https://github.com/hqw700/ScrcpyOverWebRTC>**
Upstream website / download center: <https://webrtc-phone.com/>

Publisher's website: <https://www.lin1740.de5.net/>

### 2.2 Installation

- **Method 1 (recommended)**: search for "穿云投屏" in the fnOS App Center and install directly.
- **Method 2**: install `cloudphone_all_x.y.z.fpk` manually (the package is distributed through the application release channel; this repository hosts the corresponding source code, which you can also build yourself).

Requirements and notes:

1. fnOS version ≥ 1.1.8 (`os_min_version`); one package serves both x86_64 and ARM64.
2. The first installation requires pulling the container image — typically **1–3 minutes** depending on network speed. It is recommended to configure an accelerator under fnOS "Docker → Registry → Settings → Accelerator Settings". Pull order in this package: fnOS accelerator → DaoCloud → 1ms.run → Docker Hub official, falling back automatically on failure.
3. The install wizard lets you customize ports; **fill in only what you want to change** — blank fields keep their defaults, and changing one port does not affect the others.
4. After installation the container starts automatically; the panel becomes available in about **10–60 seconds**. During the initial image pull the status page is shown, which is expected.

### 2.3 Access and Login

- **App Center entry (recommended)**: click "Open" in the App Center to enter `/app/cloudphone` through the fnOS unified gateway. TLS is terminated at the gateway, so no certificate handling is needed.
- **LAN direct access**: `https://<NAS_IP>:8443` (HTTPS by default with a self-signed certificate, CN=localhost; the browser asks you to trust it on first visit). It is recommended to replace `/app/certs/server.crt|key` with a trusted certificate matching your domain.
- **Default account**: `admin` / `admin123` — **change it immediately after the first login**. It is also recommended to change the default TURN credentials (`cloudphone_user` / `cloudphone_secure_password`).
- If you switch to custom ports, browsers and Agents must use the new ports (e.g. `https://<NAS_IP>:9443`). The App Center entry follows automatically; in the rare case it does not, **disable and re-enable** the application once.

### 2.4 Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 8443 | TCP | Web panel / signaling (HTTPS / WSS) |
| 3478 | TCP + UDP | TURN service |
| 50000-50029 | UDP | Media relay (30 ports) |

- All ports can be customized in the install wizard. After installation, inspect or change them with `bash <app_dir>/scripts/set_ports.sh`.
- **The relay range is bound by Docker port by port**: if even one port in the range is occupied by another host process, the whole mapping fails and the container stays in `Created`. The installer pre-checks the range and warns you; just pick another range as prompted.
- **Coexisting with "安卓模拟器" (Android Emulator)**: change this application to `9443 / 3479 / 51000-51100` to avoid conflicts — otherwise it cannot start because of port occupation.

### 2.5 Device Onboarding

The panel's "Deploy New Device" page offers three methods (one-click deployment without root, Magisk module, and the controlled App). All six upstream onboarding methods are documented upstream:

- WebUSB deployment in the browser (driver-free, no ADB install required — plug in and pair)
- One-click ADB script deployment from a PC (`agent-deploy.zip`)
- Magisk / KernelSU / APatch module (auto-start on boot, `cpctl` CLI for operations)
- Native Android App client (controlled side supports both rooted and Shizuku non-root modes)
- Docker / redroid cloud phone containers (requires mapping the UDP relay range)
- Custom ROM / redroid image with a built-in Agent (upstream, planned)

> **Note for cloud-phone containers**: the Agent inside a container must use an address that is reachable from the container's bridge network for signaling and TURN — do not use `127.0.0.1`. If you use the redroid container of "安卓模拟器" (Android Emulator) on the same fnOS host, use the injected hostname `host.docker.internal`, because fnOS blocks bridge containers from reaching the host's LAN IP.

### 2.6 Data and Uninstall

- Data lives in the volume `cloudphone-webrtc-data`. It is **kept by default on uninstall**; after reinstalling, accounts and device bindings are still there.
- Only an explicit "delete data as well" in the uninstall wizard removes it. That action is irreversible — back up first.

### 2.7 External Access

Prefer the official fnOS remote domain or a tunnel / reverse proxy. If you must forward ports, it is recommended to **map only TCP 8443 and use WebSocket casting** (WebRTC UDP media has stricter port-range requirements). Do not expose the ports to the public internet without protection.

### 2.8 Versioning

Version numbers track upstream: when upstream publishes a release, this application is rebuilt with the new image digest and delivered through App Center updates. Installed users are unaffected by upstream `latest` changes because the image is digest-pinned; to switch or roll back explicitly, use `scripts/set_image.sh --upgrade` / `--pin <sha256:...>`.

---

## 3. Support the Publisher

If you find this software useful, or you are satisfied with the publisher's work, you can support it through the official website: <https://www.lin1740.de5.net/> — click "赞赏支持一下" (Support via donation) and scan the corresponding code to complete a donation. Any support is greatly appreciated and helps the publisher and other contributors keep maintaining the software. Whether or not you donate, thank you all the same. When paying, please add a note "赞赏" (donation) in the remark field. Thank you.

Or simply give the project a star.

---

## 4. Feedback

1. **Publisher email**: andforlin@foxmail.com
2. **Suggestion / issue questionnaire**: <https://wj.qq.com/s2/28029808/2aab/>
3. **Issues and suggestions for the upstream CloudPhone project**: please file them in the upstream repository — <https://github.com/hqw700/ScrcpyOverWebRTC/issues>

> The first two channels are for this application (FNOS packaging, installation / upgrade / gateway / ports, etc.) and will be answered. The third is the dedicated channel for the upstream container and panel itself, which is unrelated to this packaging and handled by the upstream author.
>
> If you are not satisfied with the outcome of a report, or you want to contribute to the software, you may modify the source code in this repository directly. After building the package according to the official fnOS packaging guide, submit it through the first two channels; the publisher will audit the submitted code and invite you to become a contributor. Thanks also go to everyone who reports issues, offers suggestions, or provides substantive help. For details, see the official website: <https://www.lin1740.de5.net/>

When reporting, please include as much as possible: fnOS version, device architecture (x86_64 / ARM64), application version, relevant logs under the application data directory (`TRIM_PKGVAR`, default `/var/apps/cloudphone/var`, where the install log is `install.log`), and screenshots or screen recordings of the problem.

---

## 5. Open Source Notice

### 5.1 Upstream Project and License

At runtime this application pulls the upstream public image `buutuu/scrcpy-over-webrtc` via Docker. It does not modify, bundle, or redistribute upstream source code or binaries.

- Project: <https://github.com/hqw700/ScrcpyOverWebRTC>
- Upstream author: hqw700 (buutuu)
- License status:
  - Frontend source (web-app): [MIT License](https://opensource.org/licenses/MIT)
  - Official binary core components (server, Agent deployment bundle, APK runtime): for personal study, technical research, and non-commercial testing only

Main direct upstream dependencies:

| Component | Author / Org | License | Project |
| --- | --- | --- | --- |
| scrcpy | Genymobile | Apache-2.0 | <https://github.com/Genymobile/scrcpy> |
| ya-webadb / Tango | yume-chan | MIT | <https://github.com/yume-chan/ya-webadb> |
| Pion WebRTC | pion | MIT | <https://github.com/pion/webrtc> |
| xterm.js | xtermjs | MIT | <https://github.com/xtermjs/xterm.js> |
| coturn | coturn | BSD-3-Clause | <https://github.com/coturn/coturn> |

Transitive dependencies (Go runtime and standard library, Vue / frontend toolchain, pion libraries, WebSocket / logging libraries, etc.) are listed in the upstream `go.mod` and frontend `package.json`.

### 5.2 This Project (Build Scripts and Configuration)

- Project: <https://github.com/lin1740/fnos-ScrcpyOverWebRTC>
- Author: 键盘敲粥香 (lin1740)
- License: [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
  > In short: Apache License 2.0 permits anyone to freely use, copy, modify, merge, publish, distribute, sublicense, and sell copies of this software, provided that copyright notices, a copy of the license, and any NOTICE file are retained, and that modifications to the original files are stated. The software is provided "as is", without warranties of any kind. The license includes an express patent grant.
- Includes: FPK manifest, docker-compose orchestration, install / upgrade / uninstall scripts, install wizard, port scripts (`set_ports.sh` / `apply_ports.sh`), image pulling and version pinning (`pull_image.sh` / `set_image.sh` / `runtime.conf`), unified-gateway integration and page injection, health checks and self-healing scripts — all developed by this project to adapt the application to fnOS.
- Note: this project **does not modify the frontend or core components inside the upstream image**; the gateway only performs entry-path rewriting and page compatibility injection (for example unified-gateway paths and static asset proxying). The native upstream UI is served by the image and is outside the scope of this project.

> **License reminder**: the official binary core components of CloudPhone are for personal study, technical research, and non-commercial testing only. Contact the upstream author for commercial licensing before any commercial use.

### 5.3 Disclaimer

1. This application is an **unofficial third-party application**, provided "AS IS", without any express or implied warranty (including but not limited to merchantability, fitness for a particular purpose, and non-infringement). Use at your own risk.
2. This application is intended for study and research only and must not be used for any illegal purpose (including but not limited to unauthorized access to others' devices, evading risk controls, or distributing unlawful content). Users must ensure their use complies with local laws, regulations, and platform rules; all responsibility arising from illegal use rests with the user.
3. The publisher assumes no responsibility for any data loss, system failure, or service interruption arising from the use of this application. Back up important data yourself; the application makes no guarantee regarding the security or integrity of data in the volume.
4. Third-party components integrated in the application (CloudPhone server, Agent, panel, etc.) are maintained by the upstream author. Their functionality, stability, security posture, and compliance are outside this project's control; upstream image updates may change behavior.
5. This application listens on the ports listed above and accepts device connections. Assess your exposure yourself, change default passwords and credentials promptly, and do not expose the ports to the public internet without hardening.
6. This application does not actively collect personal privacy data; runtime data stays on your local device. However, when using upstream licensing services, necessary data such as device identifiers and network requests is sent to upstream official servers for license validation and signaling. The upstream privacy policy applies.
7. **Commercial use warning**: if you intend to use this in any commercial environment (including but not limited to internal commercial use, providing a paid cloud-phone service, pre-installing on hardware for sale, or paid delivery), you must obtain commercial authorization from the upstream author hqw700 in advance, or replace the components with commercially permissible open-source alternatives. Personal study and non-commercial family use are generally not considered commercial.

### 5.4 Other Notes

1. **Trademarks and marks**: rights to the names and marks of CloudPhone, scrcpy, WebRTC, redroid, and others belong to their respective authors or organizations. This project uses these names only for technical description, claims no trademark rights, and does not imply any official cooperation or endorsement.
2. **Endorsement**: integration of upstream components here is technical compatibility adaptation only and does not represent upstream authors' approval, recommendation, or endorsement of this project.
3. **Upstream changes**: upstream projects may change features, interfaces, or license terms across releases. This project will make a best effort to follow, but is not responsible for compatibility issues or license-status changes caused by upstream changes; refer to each upstream project's official announcements for major changes.
4. **Component integrity**: at runtime this application pulls official upstream images from public container registries and does not modify or re-package code inside those images. If you replace or modify the upstream image yourself, you are responsible for any resulting malfunction or compliance issue.
5. **Omissions and corrections**: upstream dependency graphs are complex, and some transitive dependencies or sub-components may not be listed individually or may be inaccurately labeled. If you find an open-source project that should be listed, an incorrect license status, or a broken link, please tell us through the channels in "4. Feedback"; we will verify and correct it promptly.
6. **Source code availability**: the build scripts and configuration of this project are released under Apache License 2.0, and source code is published to this repository along with releases; the actual repository content prevails.

---

## Acknowledgements

- [ScrcpyOverWebRTC / CloudPhone](https://github.com/hqw700/ScrcpyOverWebRTC) — WebRTC screen service, Agent, and web panel
- [scrcpy](https://github.com/Genymobile/scrcpy), [Pion WebRTC](https://github.com/pion/webrtc), [ya-webadb](https://github.com/yume-chan/ya-webadb), [xterm.js](https://github.com/xtermjs/xterm.js), [coturn](https://github.com/coturn/coturn) — upstream dependencies
- The fnOS developer community
