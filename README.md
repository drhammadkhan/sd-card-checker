# SD Card Checker

A native macOS app (SwiftUI, macOS 14+) for checking the health of SD cards and other removable drives.

## Build & run

    ./build.sh
    open "build/SD Card Checker.app"

Drag `build/SD Card Checker.app` into /Applications to install it. On first launch, macOS asks for permission to access removable volumes. Click **Allow**.

## Health checks

| Test | What it does | Writes to card? |
|---|---|---|
| **Speed Test** | Writes a temp file (256 MB–4 GB), verifies it, measures sequential + random 4K speed, estimates speed class (Class 10/U3/V30…) and app class (A1/A2). | Temp file, then deletes it |
| **Full Capacity & Integrity Test** | Like H2testw/F3: fills all *free* space with a position-dependent pattern, then reads every byte back. Detects counterfeit (fake-capacity) cards and failing flash, and estimates the real capacity. | Fills free space, then deletes the test files (optional) |
| **Surface Scan** | Reads every sector of the whole device (`/dev/rdiskN`): partition table, file system areas and your files. Lists unreadable sectors as ranges and flags unusually slow areas on a colour map of the card. macOS asks for your admin password through Apple's `authopen`, and the app never runs as root. | No |
| **Read Scan** | Reads every existing file to find unreadable areas. Works on write-protected cards. | No |

Existing files are never modified. Test data lives in a `SDCardChecker-Test` folder. If a run is interrupted, the app offers to remove leftovers next time.

All I/O bypasses the macOS cache (`F_NOCACHE`) so results reflect the card itself. Speeds may still be capped by your card reader or USB port.
