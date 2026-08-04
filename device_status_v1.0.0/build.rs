// Injects Windows VERSIONINFO metadata (file description, product name, version, etc.)
// into the binary. No-op on non-Windows, so `cargo check` still works elsewhere.

fn main() {
    #[cfg(windows)]
    {
        let major: u16 = env!("CARGO_PKG_VERSION_MAJOR").parse().unwrap();
        let minor: u16 = env!("CARGO_PKG_VERSION_MINOR").parse().unwrap();
        let patch: u16 = env!("CARGO_PKG_VERSION_PATCH").parse().unwrap();
        // VERSIONINFO format: major.minor.patch.build (4x u16 packed into u64)
        let version_u64: u64 =
            ((major as u64) << 48) | ((minor as u64) << 32) | ((patch as u64) << 16) | 0u64;

        let mut res = winresource::WindowsResource::new();
        res.set("FileDescription", "Serial Board, Phone & Drive Status Monitor")
            .set("ProductName", "Device Status")
            .set("CompanyName", "Prime Enterprises")
            .set("LegalCopyright", "Copyright (c) 2026 Prime Enterprises. All rights reserved.")
            .set("OriginalFilename", "device_status.exe")
            .set("InternalName", "device_status")
            .set_version_info(winresource::VersionInfo::FILEVERSION, version_u64)
            .set_version_info(winresource::VersionInfo::PRODUCTVERSION, version_u64);

        if let Err(e) = res.compile() {
            // Fail loudly — if winresource breaks (no rc.exe, etc.),
            // you want to know at build time, not when inspecting Properties later.
            eprintln!("Failed to compile Windows resources: {e}");
            std::process::exit(1);
        }
    }
}
