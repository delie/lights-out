import Foundation

/// Short brand names for common monitor makers, keyed by EDID maker code (e.g. "PHL").
/// The official PNP ID list has ~2,500 entries with legal names ("ASUSTek COMPUTER INC"),
/// so this keeps just the brands people buy. Some makers use more than one code.
/// Makers not listed here are shown by their 3-letter code.
enum MonitorBrands {
    static func name(forManufacturerCode code: String) -> String? {
        brandsByManufacturerCode[code]
    }

    private static let brandsByManufacturerCode: [String: String] = [
        "ACI": "ASUS", "ACR": "Acer", "AOC": "AOC", "APP": "Apple", "AUS": "ASUS",
        "BNQ": "BenQ", "CRM": "Corsair", "DEL": "Dell", "ENC": "EIZO", "FUS": "Fujitsu",
        "GBT": "Gigabyte", "GGL": "Google", "GSM": "LG", "HEC": "Hisense", "HKC": "HKC",
        "HPN": "HP", "HRE": "Haier", "HSD": "HannStar", "HWP": "HP", "HWV": "Huawei",
        "IVM": "iiyama", "LEN": "Lenovo", "LNV": "Lenovo", "MAT": "Panasonic", "MEI": "Panasonic",
        "MSG": "MSI", "MSH": "Microsoft", "MSI": "MSI", "NEC": "NEC", "NMV": "NEC",
        "PHL": "Philips", "PNR": "Planar", "RZR": "Razer", "SAM": "Samsung", "SEM": "Samsung",
        "SHP": "Sharp", "SNY": "Sony", "SON": "Sony", "SPT": "Sceptre", "TOL": "TCL",
        "VIZ": "Vizio", "VSC": "ViewSonic", "WAC": "Wacom", "XMI": "Xiaomi",
    ]
}
