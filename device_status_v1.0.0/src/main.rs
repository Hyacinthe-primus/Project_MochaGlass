use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use serialport::SerialPortType;
use wmi::{COMLibrary, WMIConnection};

struct BoardInfo {
    name: &'static str,
    icon: &'static str,
    color: &'static str,
}

fn boards() -> HashMap<(u16, u16), BoardInfo> {
    let mut m = HashMap::new();
    m.insert(
        (0x1A86, 0x55D3),
        BoardInfo { name: "ESP32-S3", icon: "\u{ec19}", color: "#f9e2af" },
    );
    m.insert(
        (0x2341, 0x0043),
        BoardInfo { name: "Arduino Uno", icon: "\u{e266}", color: "#89b4fa" },
    );
    m
}

const DEFAULT_ICON: &str = "\u{f2db}";
const DEFAULT_COLOR: &str = "#cdd6f4";

fn phone_style(kind: &str) -> (&'static str, &'static str) {
    match kind {
        "iphone" => ("\u{f8ff}", "#f38ba8"),
        _ => ("\u{e70e}", "#a6e3a1"),
    }
}

fn drive_style(kind: &str) -> (&'static str, &'static str) {
    match kind {
        "usb_drive" => ("\u{f129f}", "#94e2d5"),
        _ => ("\u{f02ca}", "#fab387"),
    }
}

#[derive(Serialize, Deserialize, Clone)]
struct DeviceInfo {
    port: String,
    name: String,
    icon: String,
    color: String,
    vid: String,
    pid: String,
    manufacturer: String,
    description: String,
}

#[derive(Serialize)]
struct Output {
    compact: String,
    count: usize,
    tooltip: String,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "PascalCase")]
struct PnpEntityRow {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    device_id: Option<String>,
    #[serde(default)]
    pnp_class: Option<String>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "PascalCase")]
struct DiskDriveRow {
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    media_type: Option<String>,
    #[serde(default)]
    index: Option<i32>,
    #[serde(default)]
    interface_type: Option<String>,
    #[serde(default)]
    pnp_device_id: Option<String>,
}

fn resolve_serial_ports() -> Vec<DeviceInfo> {
    let table = boards();
    let mut out = Vec::new();

    let ports = match serialport::available_ports() {
        Ok(p) => p,
        Err(_) => return out,
    };

    for p in ports {
        if let SerialPortType::UsbPort(usb) = p.port_type {
            let vid = usb.vid;
            let pid = usb.pid;
            let known = table.get(&(vid, pid));

            let name = known
                .map(|b| b.name.to_string())
                .or_else(|| usb.product.clone())
                .unwrap_or_else(|| "Unknown board".to_string());
            let icon = known.map(|b| b.icon).unwrap_or(DEFAULT_ICON).to_string();
            let color = known.map(|b| b.color).unwrap_or(DEFAULT_COLOR).to_string();

            out.push(DeviceInfo {
                port: p.port_name.clone(),
                name,
                icon,
                color,
                vid: format!("{:04X}", vid),
                pid: format!("{:04X}", pid),
                manufacturer: usb.manufacturer.unwrap_or_else(|| "?".to_string()),
                description: usb.product.unwrap_or_else(|| "?".to_string()),
            });
        }
    }
    out
}

fn classify_phone(friendly_name: &str, pnp_class: Option<&str>) -> &'static str {
    let lower = friendly_name.to_lowercase();
    if lower.contains("iphone") || lower.contains("apple") || pnp_class == Some("AppleUSB") {
        "iphone"
    } else {
        "android"
    }
}

fn classify_drive(media_type: Option<&str>) -> &'static str {
    match media_type {
        Some(mt) if mt.to_lowercase().contains("removable") => "usb_drive",
        _ => "external_hdd",
    }
}

fn extract_vid_pid(instance_id: &str) -> (String, String) {
    let mut vid = "?".to_string();
    let mut pid = "?".to_string();
    for part in instance_id.split('\\') {
        if part.starts_with("VID_") {
            for seg in part.split('&') {
                if let Some(v) = seg.strip_prefix("VID_") {
                    vid = v.to_string();
                } else if let Some(p) = seg.strip_prefix("PID_") {
                    pid = p.to_string();
                }
            }
        }
    }
    (vid, pid)
}

/// Extracts a stable USB serial from the tail of a Windows instance ID.
fn extract_serial(instance_id: &str) -> Option<String> {
    let last_segment = instance_id.rsplit('\\').next()?;
    let serial = last_segment.split('&').next().unwrap_or(last_segment).trim();
    if serial.is_empty() {
        None
    } else {
        Some(serial.to_uppercase())
    }
}

fn detect_usb_extras() -> Vec<DeviceInfo> {
    let mut out = Vec::new();

    let com_con = match COMLibrary::new() {
        Ok(c) => c,
        Err(_) => return out,
    };
    let wmi_con = match WMIConnection::new(com_con.into()) {
        Ok(c) => c,
        Err(_) => return out,
    };

    // BusType 7 = USB, from the Storage Management namespace (more reliable
    // than Win32_DiskDrive for drives behind a USB enclosure).
    let usb_physical_disk_indices: HashSet<i32> = COMLibrary::new()
        .ok()
        .and_then(|c| {
            WMIConnection::with_namespace_path("ROOT\\Microsoft\\Windows\\Storage", c).ok()
        })
        .map(|storage_con| {
            #[derive(Deserialize, Debug)]
            #[serde(rename_all = "PascalCase")]
            struct PhysicalDiskRow {
                #[serde(default)]
                device_id: Option<String>,
                #[serde(default)]
                bus_type: Option<u16>,
            }
            let rows: Vec<PhysicalDiskRow> = storage_con
                .raw_query("SELECT DeviceId, BusType FROM MSFT_PhysicalDisk")
                .unwrap_or_default();
            rows.into_iter()
                .filter(|r| r.bus_type == Some(7))
                .filter_map(|r| r.device_id.and_then(|s| s.trim().parse::<i32>().ok()))
                .collect()
        })
        .unwrap_or_default();

    // Drives are indexed first so the WPD loop below can merge composite
    // USB media (disk + WPD entries for the same device) into one entry.
    let mut drive_serial_index: HashMap<String, usize> = HashMap::new();
    let mut drive_letter_index: HashMap<String, usize> = HashMap::new();
    let mut drive_name_index: HashMap<String, usize> = HashMap::new();

    let disks: Vec<DiskDriveRow> = wmi_con
        .raw_query(
            "SELECT Model, Size, MediaType, Index, InterfaceType, PNPDeviceID FROM Win32_DiskDrive",
        )
        .unwrap_or_default();

    for disk in disks {
        let is_usb = disk
            .index
            .map(|i| usb_physical_disk_indices.contains(&i))
            .unwrap_or(false)
            || disk.interface_type.as_deref() == Some("USB")
            || disk
                .pnp_device_id
                .as_deref()
                .map(|id| id.to_uppercase().starts_with("USBSTOR"))
                .unwrap_or(false);
        if !is_usb {
            continue;
        }
        let size_gb = disk
            .size
            .map(|b| format!("{:.1} GB", b as f64 / 1_073_741_824.0))
            .unwrap_or_else(|| "?".to_string());

        let label = disk.model.clone().unwrap_or_else(|| "USB Drive".to_string());
        let media_type = disk.media_type.clone();
        let kind = classify_drive(media_type.as_deref());
        let (icon, color) = drive_style(kind);

        let serial = disk.pnp_device_id.as_deref().and_then(extract_serial);

        // DiskDrive -> Partition -> LogicalDisk
        let letter = disk
            .index
            .and_then(|idx| {
                let assoc_q = format!(
                    "ASSOCIATORS OF {{Win32_DiskDrive.DeviceID='\\\\.\\PHYSICALDRIVE{}'}} \
                     WHERE AssocClass = Win32_DiskDriveToDiskPartition",
                    idx
                );
                #[derive(Deserialize)]
                #[serde(rename_all = "PascalCase")]
                struct PartRow {
                    device_id: Option<String>,
                }
                let parts: Vec<PartRow> = wmi_con.raw_query(&assoc_q).unwrap_or_default();
                parts.into_iter().find_map(|p| p.device_id)
            })
            .and_then(|part_id| {
                let q2 = format!(
                    "ASSOCIATORS OF {{Win32_DiskPartition.DeviceID='{}'}} \
                     WHERE AssocClass = Win32_LogicalDiskToPartition",
                    part_id.replace('\'', "''")
                );
                #[derive(Deserialize)]
                #[serde(rename_all = "PascalCase")]
                struct LDiskRow {
                    device_id: Option<String>,
                }
                let ld: Vec<LDiskRow> = wmi_con.raw_query(&q2).unwrap_or_default();
                ld.into_iter().find_map(|d| d.device_id)
            })
            .unwrap_or_else(|| "?".to_string());

        let idx = out.len();
        out.push(DeviceInfo {
            port: letter.clone(),
            name: label.clone(),
            icon: icon.to_string(),
            color: color.to_string(),
            vid: size_gb,
            pid: "USB".to_string(),
            manufacturer: "?".to_string(),
            description: media_type.unwrap_or_else(|| "?".to_string()),
        });

        if let Some(s) = serial {
            drive_serial_index.insert(s, idx);
        }
        if letter != "?" {
            drive_letter_index.insert(letter.trim_end_matches('\\').to_uppercase(), idx);
        }
        drive_name_index.insert(label.trim().to_lowercase(), idx);
    }

    // Phones: PnPEntity filtered by class (WPD / AppleUSB)
    let phones: Vec<PnpEntityRow> = wmi_con
        .raw_query(
            "SELECT Name, DeviceID, PNPClass FROM Win32_PnPEntity \
             WHERE PNPClass='WPD' OR PNPClass='AppleUSB'",
        )
        .unwrap_or_default();

    for entry in phones {
        let friendly_name = entry.name.clone().unwrap_or_else(|| "Unknown device".to_string());
        let device_id = entry.device_id.clone().unwrap_or_default();
        let device_id_upper = device_id.to_uppercase();

        // Match to an already-listed drive by serial containment, falling
        // back to drive letter / model name.
        let matched_idx = drive_serial_index
            .iter()
            .find(|(serial, _)| device_id_upper.contains(serial.as_str()))
            .map(|(_, &idx)| idx)
            .or_else(|| {
                let name_as_letter = friendly_name.trim().trim_end_matches('\\').to_uppercase();
                drive_letter_index.get(&name_as_letter).copied()
            })
            .or_else(|| drive_name_index.get(&friendly_name.trim().to_lowercase()).copied());

        if let Some(idx) = matched_idx {
            // Prefer the WPD friendly name over the raw drive letter when it
            // adds information (e.g. a volume label vs generic model string).
            let name_as_letter = friendly_name.trim().trim_end_matches('\\').to_uppercase();
            let port_as_letter = out[idx].port.trim_end_matches('\\').to_uppercase();
            if !friendly_name.trim().is_empty() && name_as_letter != port_as_letter {
                out[idx].name = friendly_name;
            }
            continue;
        }

        let kind = classify_phone(&friendly_name, entry.pnp_class.as_deref());
        let (icon, color) = phone_style(kind);
        let (vid, pid) = extract_vid_pid(&device_id);

        out.push(DeviceInfo {
            port: String::new(),
            name: friendly_name,
            icon: icon.to_string(),
            color: color.to_string(),
            vid,
            pid,
            manufacturer: "?".to_string(),
            description: entry.pnp_class.unwrap_or_else(|| "?".to_string()),
        });
    }

    out
}

const EXTRAS_INTERVAL_SECONDS: u64 = 10;

#[derive(Serialize, Deserialize)]
struct Cache {
    timestamp: u64,
    devices: Vec<DeviceInfo>,
}

fn cache_path() -> PathBuf {
    std::env::temp_dir().join("device_status_extras_cache.json")
}

fn get_usb_extras_throttled() -> Vec<DeviceInfo> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    if let Ok(raw) = fs::read_to_string(cache_path()) {
        if let Ok(cached) = serde_json::from_str::<Cache>(&raw) {
            if now.saturating_sub(cached.timestamp) < EXTRAS_INTERVAL_SECONDS {
                return cached.devices;
            }
        }
    }

    let devices = detect_usb_extras();
    let cache = Cache { timestamp: now, devices: devices.clone() };
    if let Ok(json) = serde_json::to_string(&cache) {
        let _ = fs::write(cache_path(), json);
    }
    devices
}

fn main() {
    let mut devices = resolve_serial_ports();
    devices.extend(get_usb_extras_throttled());

    let out = if devices.is_empty() {
        Output {
            compact: "No device".to_string(),
            count: 0,
            tooltip: "No device detected".to_string(),
        }
    } else {
        let label = |d: &DeviceInfo| {
            if d.port.is_empty() {
                d.name.clone()
            } else {
                format!("{} ({})", d.name, d.port)
            }
        };

        let compact = devices
            .iter()
            .map(|d| format!("<span style='color:{}'>{} {}</span>", d.color, d.icon, label(d)))
            .collect::<Vec<_>>()
            .join(" \u{2022} ");

        let tooltip = devices
            .iter()
            .map(|d| {
                format!(
                    "{}\n  Manufacturer : {}\n  VID:PID   : {}:{}\n  Description : {}",
                    label(d),
                    d.manufacturer,
                    d.vid,
                    d.pid,
                    d.description
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n");

        Output { compact, count: devices.len(), tooltip }
    };

    println!("{}", serde_json::to_string(&out).unwrap());
}