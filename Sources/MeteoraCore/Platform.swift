#if canImport(AppKit)
import AppKit
/// Font and colour types of the current platform (export code is shared by
/// the Mac and iPhone apps).
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#else
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif
