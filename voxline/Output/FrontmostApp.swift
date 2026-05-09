// voxline/Output/FrontmostApp.swift
import AppKit

/// Real-NSWorkspace impl of FrontmostAppProviding. Tests substitute a fake.
struct FrontmostApp: FrontmostAppProviding {
    func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
