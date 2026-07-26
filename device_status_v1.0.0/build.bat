@echo off
setlocal

:: Read version from nuitka.manifest.json via PowerShell JSON parsing
:: (findstr substring matching was unreliable across file_version/product_version/version keys)
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "(Get-Content nuitka.manifest.json | ConvertFrom-Json).version"`) do set "VERSION=%%a"

echo Building device_status v%VERSION%...

nuitka ^
  --standalone ^
  --windows-console-mode=disable ^
  --company-name="Prime Enterprises" ^
  --product-name="Device Status" ^
  --file-version=%VERSION%.0 ^
  --product-version=%VERSION%.0 ^
  --file-description="Serial Board, Phone & Drive Status Monitor" ^
  --copyright="Copyright (c) 2026 Prime Enterprises. All rights reserved." ^
  --include-package=serial ^
  --include-package=serial.tools ^
  --include-module=serial.tools.list_ports ^
  --output-filename=device_status.exe ^
  --output-dir=dist ^
  --assume-yes-for-downloads ^
  device_status.py

echo.
echo Build complete: dist\device_status.dist\device_status.exe (v%VERSION%)
echo IMPORTANT: point your status bar launcher at the .exe INSIDE device_status.dist\,
echo not a standalone file directly in dist\ - --onefile was removed, this is now a folder build.
pause
