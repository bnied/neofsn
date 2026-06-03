import Foundation
import AppKit

/// Categorical classification of a filesystem item by extension. Drives both the
/// SF Symbol shown on file slabs and the type-based color palette in the 3D scene.
enum FileKind {
    case folder
    case code
    case image
    case audio
    case video
    case document
    case archive
    case config
    case web
    case executable
    case disk
    case hidden
    case other

    /// Classify a node by name + isDirectory. Hidden dotfiles win over their extension.
    static func classify(name: String, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ext.isEmpty {
            return lower.hasPrefix(".") ? .hidden : .other
        }
        switch ext {
        case "swift", "m", "h", "c", "cpp", "cc", "rs", "go", "py", "js", "ts",
             "tsx", "jsx", "rb", "java", "kt", "lua", "pl", "php", "r":
            return .code
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp", "svg":
            return .image
        case "mp3", "wav", "aiff", "aif", "flac", "m4a", "ogg", "opus":
            return .audio
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return .video
        case "pdf", "doc", "docx", "txt", "md", "rtf", "tex", "pages", "epub":
            return .document
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return .archive
        case "json", "xml", "yaml", "yml", "toml", "plist", "ini", "conf", "cfg", "env":
            return .config
        case "html", "htm", "css", "scss", "sass", "less":
            return .web
        case "app", "sh", "bash", "zsh", "fish", "command", "exe":
            return .executable
        case "dmg", "iso", "img":
            return .disk
        default:
            return .other
        }
    }

    /// SF Symbol used as the flat icon on a file slab.
    var iconName: String {
        switch self {
        case .folder:     return "folder.fill"
        case .code:       return "curlybraces"
        case .image:      return "photo"
        case .audio:      return "waveform"
        case .video:      return "film"
        case .document:   return "doc.text"
        case .archive:    return "archivebox"
        case .config:     return "list.bullet.indent"
        case .web:        return "globe"
        case .executable: return "terminal"
        case .disk:       return "opticaldiscdrive"
        case .hidden:     return "gearshape"
        case .other:      return "doc"
        }
    }

    /// Human label for the kind chip in the metadata HUD.
    var label: String {
        switch self {
        case .folder:     return "folder"
        case .code:       return "code"
        case .image:      return "image"
        case .audio:      return "audio"
        case .video:      return "video"
        case .document:   return "document"
        case .archive:    return "archive"
        case .config:     return "config"
        case .web:        return "web"
        case .executable: return "executable"
        case .disk:       return "disk"
        case .hidden:     return "hidden"
        case .other:      return "file"
        }
    }

    /// Saturated palette used when the scene is in `.type` color mode. Each kind
    /// gets a distinct jewel tone so the scene reads as a categorical legend.
    var sceneColor: NSColor {
        switch self {
        case .folder:
            return NSColor(calibratedRed: 0.28, green: 0.62, blue: 0.88, alpha: 1) // macOS Finder blue
        case .code:
            return NSColor(calibratedRed: 0.30, green: 0.72, blue: 0.85, alpha: 1) // cyan
        case .image:
            return NSColor(calibratedRed: 0.88, green: 0.38, blue: 0.62, alpha: 1) // magenta
        case .audio:
            return NSColor(calibratedRed: 0.62, green: 0.44, blue: 0.82, alpha: 1) // violet
        case .video:
            return NSColor(calibratedRed: 0.94, green: 0.42, blue: 0.40, alpha: 1) // coral
        case .document:
            return NSColor(calibratedRed: 0.86, green: 0.80, blue: 0.66, alpha: 1) // cream
        case .archive:
            return NSColor(calibratedRed: 0.66, green: 0.48, blue: 0.32, alpha: 1) // brown
        case .config:
            return NSColor(calibratedRed: 0.78, green: 0.82, blue: 0.30, alpha: 1) // yellow-green
        case .web:
            return NSColor(calibratedRed: 0.40, green: 0.62, blue: 0.88, alpha: 1) // sky blue
        case .executable:
            return NSColor(calibratedRed: 0.48, green: 0.80, blue: 0.42, alpha: 1) // green
        case .disk:
            return NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.72, alpha: 1) // silver
        case .hidden:
            return NSColor(calibratedRed: 0.42, green: 0.42, blue: 0.46, alpha: 1) // muted gray
        case .other:
            return NSColor(calibratedRed: 0.58, green: 0.58, blue: 0.60, alpha: 1) // neutral
        }
    }
}
