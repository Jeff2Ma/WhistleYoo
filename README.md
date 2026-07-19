<p align="center">
  <img src="Sources/whistleYooApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-256@2x.png" width="104" alt="WhistleYoo icon">
</p>

<h1 align="center">WhistleYoo</h1>

<p align="center">
  A native macOS menu bar experience for running, controlling, and configuring Whistle.
</p>

<p align="center">
  <strong>English</strong> · <a href="README_zh.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/Jeff2Ma/WhistleYoo/releases/latest"><img src="https://img.shields.io/github/v/release/Jeff2Ma/WhistleYoo?display_name=tag&sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple" alt="macOS 13 or later">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Jeff2Ma/WhistleYoo" alt="MIT License"></a>
</p>

WhistleYoo is an open-source macOS companion for [Whistle](https://github.com/avwo/whistle). It uses the Node.js runtime and globally installed Whistle already on your Mac, runs a dedicated Whistle instance with isolated storage, and brings everyday tasks into a native app: starting the proxy, routing system traffic, inspecting requests, managing rules, configuring mobile devices, and maintaining the HTTPS root certificate.

<p align="center">
  <img src="docs/screenshots/00-popover.png" width="430" alt="WhistleYoo menu bar control panel">
</p>

## Why WhistleYoo

- **Always available from the menu bar**: See the proxy engine and system proxy state at a glance, then start, stop, or quit whenever needed.
- **Native system proxy management**: Route selected macOS network services through WhistleYoo and restore settings changed by the app when it quits.
- **The full Whistle console**: Inspect requests and use familiar Whistle tools such as Inspectors, Timeline, Replay, and Composer without leaving the app.
- **Native rule management**: Search, create, enable, disable, and reorder Whistle rule sets with support for the complete Whistle rule syntax.
- **Guided mobile setup**: Copy the local proxy details and download the HTTPS root certificate with a QR code.
- **Isolated and portable**: Keep Whistle's default storage untouched and save settings plus rules in one JSON configuration file.
- **English and Chinese UI with in-app updates**: Follow the macOS language and check for new releases through Sparkle.

## Download and Requirements

Download the latest Universal DMG from [GitHub Releases](https://github.com/Jeff2Ma/WhistleYoo/releases/latest). The app supports both Apple silicon and Intel Macs.

WhistleYoo requires:

| Component | Minimum requirement |
| --- | --- |
| macOS | 13 Ventura or later |
| Node.js | 18 or later |
| Whistle | 2.9 or later, installed globally |

If Whistle is not installed yet:

```bash
npm install -g whistle
```

You can verify the environment in Terminal first:

```bash
node --version
w2 -V
```

WhistleYoo looks for Node.js and Whistle in locations managed by Homebrew, nvm, fnm, Volta, and other common local installation paths.

> WhistleYoo does not bundle or upgrade Node.js and Whistle for you. You can keep using your preferred version manager without introducing a second, hidden runtime inside the app.

## Installation

1. Download and open `WhistleYoo-X.Y.Z.dmg`.
2. Drag `WhistleYoo.app` into the Applications folder.
3. Open WhistleYoo from Applications and follow the Setup Assistant.

The current public builds use ad-hoc code signing and have not yet been signed with an Apple Developer ID or notarized by Apple. macOS may report that it cannot verify the developer the first time you open the app. Confirm that the DMG came from this repository's Releases page, then Control-click the app in Finder, choose **Open**, and confirm once more.

## First Run

The Setup Assistant walks through four steps:

1. **Check the runtime environment**: Confirm that Node.js and Whistle are ready. If either is missing, copy the installation command and check again.
2. **Check the ports**: The default proxy port is `8899` and the default Web UI port is `8900`. You can change either port if it conflicts with another process.
3. **Install the HTTPS root certificate**: Install it when you need to inspect decrypted HTTPS traffic. You can skip this step if you only capture HTTP or do not need HTTPS decryption yet.
4. **Finish setup**: The proxy engine is now running, and you can choose whether to enable the Global System Proxy immediately.

On ordinary launches after setup, WhistleYoo stays idle and does not automatically take over Mac traffic. When you need it, click the menu bar icon, start the proxy engine, and enable the Global System Proxy only if required.

### Understanding the Two Controls

- **Proxy Engine** controls WhistleYoo's dedicated Whistle instance. Once it is running, mobile devices and manually configured clients can already use the proxy.
- **Global System Proxy** routes the selected macOS network services through that instance. When it is off, Mac traffic is not routed automatically, but mobile and manually configured clients remain available.

Closing the main window does not quit the menu bar app. When you are finished, choose **Shut Down and Quit** from the menu bar panel. WhistleYoo first restores the system proxy settings it manages, then stops its dedicated Whistle instance.

## Inspecting and Debugging Requests

After starting the proxy, open **Whistle Console** to use the embedded Web UI. It preserves familiar Whistle workflows such as Network, Inspectors, Timeline, Replay, and Composer for inspecting request details, replaying traffic, and debugging APIs.

![Embedded Whistle console in WhistleYoo](docs/screenshots/01-console.png)

To proxy only one application temporarily, leave the Global System Proxy off and configure that application's HTTP/HTTPS proxy manually as `127.0.0.1:8899`.

## Managing Whistle Rules

**Rule Configuration** reads and writes the Rules data of WhistleYoo's dedicated Whistle instance directly. It does not maintain a second copy that Whistle cannot see.

- Search rule sets by name or content.
- Create, rename, or delete custom rule sets.
- Enable multiple rule sets and drag them into their effective order.
- Edit the complete Whistle rule syntax and press `Command + S` to save.
- Receive a warning about unsaved changes before refreshing or leaving.

`Default` is a reserved rule set managed by WhistleYoo. It is always enabled and cannot be edited, renamed, or deleted. Compatibility Domain Filtering is also applied through this rule set and is managed centrally in Settings.

![Native rule configuration in WhistleYoo](docs/screenshots/03-rules.png)

See the [official Whistle documentation](https://wproxy.org/whistle/) for the rule syntax.

## Capturing Mobile Traffic

1. Connect the mobile device and Mac to the same local network.
2. Start the proxy engine and open **Mobile Proxy**.
3. Select the physical network address marked **Recommended**, then copy the proxy details.
4. In the mobile device's current Wi-Fi settings, set HTTP Proxy to **Manual** and enter the displayed server and port.
5. To capture HTTPS, scan the QR code and install and trust the root certificate on the mobile device.

![Mobile proxy setup in WhistleYoo](docs/screenshots/02-mobile.png)

If the device cannot connect, first confirm that both devices are on the same local network, that you used the recommended LAN address, and that the macOS firewall or Wi-Fi client isolation is not blocking the connection.

## Settings, Certificates, and Configuration

Settings lets you manage:

- Launch at login and whether WhistleYoo appears in the Dock.
- The proxy port, Web UI port, and macOS network services that use the system proxy.
- Whether the HTTPS root certificate is installed, trusted, and matched to the current Whistle instance.
- Compatibility Domain Filtering for Apple, iCloud, JetBrains, and other services.
- The location, import, and export of the WhistleYoo configuration file.

![WhistleYoo settings](docs/screenshots/04-settings.png)

The default configuration file is:

```text
~/Library/Application Support/com.devework.whistleyoo/WhistleYoo.json
```

This JSON file contains both app settings and the complete rules snapshot. You can move it to iCloud Drive or another synchronized directory from Settings to reuse the configuration across Macs. Because it may contain local paths, domains, and complete rules, do not upload it to a public location without reviewing it first.

## Troubleshooting

### Node.js or Whistle Cannot Be Found

Confirm that both versions meet the requirements and run `npm install -g whistle` in Terminal. If you just installed them, return to the Setup Assistant or open **Settings → Runtime Environment**, then click **Check Again**.

### The Proxy Engine Does Not Start

Another process may already be using port `8899` or `8900`. Open **Settings → Proxy and Ports** and choose different ports. WhistleYoo does not silently select random ports when a conflict occurs.

### No Mac Requests Appear in the Whistle Console

First confirm that the proxy engine is running. To route Mac traffic automatically, you must also enable the Global System Proxy. If you are proxying only one application, check that application's manual proxy host and port.

### HTTPS Requests Appear but Their Contents Are Not Decrypted

Open **Settings → HTTPS Root Certificate** and confirm that the certificate is installed, trusted, and matched to the current Whistle instance. Services covered by Compatibility Domain Filtering intentionally bypass HTTPS decryption and are hidden from the request list.

### WhistleYoo Does Not Appear in the Dock

WhistleYoo runs as a menu bar app by default. Click its menu bar icon to open the control panel, or enable **Show WhistleYoo in the Dock** in Settings.

## Updates, Feedback, and Privacy

- Use **About → Check for Updates** to get a new release. Update packages are verified with a Sparkle EdDSA signature.
- Report problems or suggest improvements through [GitHub Issues](https://github.com/Jeff2Ma/WhistleYoo/issues).
- WhistleYoo starts and manages Whistle locally. Configuration, rules, and certificate records stay in the current user's directories; the app does not provide a hosted proxy or account service.

For source builds, code signing, Sparkle keys, and automated releases, see the [Maintainer Guide](docs/maintainer-guide.md) (Chinese).

## License

[MIT](LICENSE) © 2026 Jeff Ma
