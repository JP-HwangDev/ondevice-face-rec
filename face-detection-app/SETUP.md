# Face Detection App — Xcode Setup Guide

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later
- iOS 16+ device (camera required — simulator not supported)
- CocoaPods

---

## 1. Install CocoaPods

If CocoaPods is not installed:

```bash
sudo gem install cocoapods
```

---

## 2. Install dependencies

```bash
cd face-detection-app
pod install
```

---

## 3. Open in Xcode

**Always open the workspace, not the project file.**

```bash
open FaceDetecting.xcworkspace
```

Or in Xcode: File → Open → select `FaceDetecting.xcworkspace`

---

## 4. Set your Development Team

1. In Xcode, select the **FaceDetecting** target (left sidebar → blue icon)
2. Go to **Signing & Capabilities** tab
3. Under **Team**, select your Apple Developer account
4. Change **Bundle Identifier** if needed (e.g. `com.yourname.FaceDetecting`)

---

## 5. Server Configuration

The app connects to the attendance API server. Update the base URL in:

```
FaceDetecting/Services/APIService.swift
```

```swift
private let baseURL = "http://YOUR_SERVER_IP:9000/api"
```

Also add the server IP to `Info.plist` under `NSAppTransportSecurity → NSExceptionDomains` if using HTTP.

---

## 6. Build & Run

- Connect a physical iOS device (camera required)
- Select the device in Xcode's toolbar
- Press **⌘R** to build and run

---

## Model

`AuraFace.mlmodel` (512-dim face embedding, Apache-2.0 license) is tracked via Git LFS.

If the model file is missing (shows as pointer file), run:

```bash
git lfs install
git lfs pull
```

---

## Project Structure

```
face-detection-app/
├── FaceDetecting.xcodeproj/     ← Xcode project
├── FaceDetecting/
│   ├── ContentView.swift        ← Main UI
│   ├── FaceViewModel.swift      ← Camera + recognition logic
│   ├── FaceModel.swift          ← Local SQLite store
│   ├── AuraFace.mlmodel         ← Face embedding model (Git LFS)
│   ├── Models/                  ← Data models
│   ├── Services/                ← API service
│   └── Views/                   ← Face registration view
├── Info.plist
├── Podfile
└── SETUP.md
```
