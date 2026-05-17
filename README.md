# Screenpipe Build Free (macOS arm64)

This repository provides an automated, "free" (unsigned) build of [Screenpipe](https://github.com/screenpipe/screenpipe) for macOS Apple Silicon.

## 🚀 Features
- **Unsigned Build:** No Apple Developer ID or notarization required.
- **Automated Updates:** Automatically checks for and builds new releases from the upstream Screenpipe repository every 4 hours.
- **Optimized for M1/M2/M3:** Specifically configured for Apple Silicon (macOS 14+).
- **Fast Builds:** Uses GitHub Actions caching for Rust, Bun, and Next.js to ensure rapid delivery.
- **Stability Patches:** Includes runtime patches to fix upstream crashes (e.g. CoreAudio EXC_BAD_ACCESS).
- **Ad-Hoc Signing:** Uses deep ad-hoc signing so the app remains functional without official certificates.

## 📥 How to Download
1. Go to the [Actions](https://github.com/Rahulsharma0810/screenpipe-build-free/actions) tab.
2. Select the latest successful **Build Free Screenpipe** run.
3. Scroll down to **Artifacts** and download `screenpipe-macos-arm64`.
4. Extract the `.zip` or open the `.dmg`.
5. **First Launch:**
   - Drag `screenpipe.app` to your `/Applications` folder.
   - **Right-click** (Control-click) the app and select **Open**.
   - Click **Open** again in the macOS security dialog.

## ⚙️ How it Works
This repository uses a GitHub Actions workflow (`build-free.yml`) that:
1. Automatically identifies the latest release tag from the upstream Screenpipe repository.
2. Checks out the source code at that tag.
3. Applies surgical patches for common build issues and runtime crashes.
4. Strips signing and notarization requirements from the Tauri configuration.
5. Builds a production-optimized release using Cargo and Bun.
6. Deep-signs the resulting bundle ad-hoc.

## 🛠 Manual Build
To trigger a build manually:
1. Click **Run workflow** in the Actions tab.
2. (Optional) Provide a specific tag or branch from the upstream repository.

---
*Maintained by [Rahulsharma0810](https://github.com/Rahulsharma0810)*
