import Foundation

/// 版本单一事实源（ADR-022：源码分发 + 版本锚定决议，2026-08-29）。
/// `pini version` 与 CHANGELOG 均引用此常量；发布时随 tag 更新。
public enum PiniVersion {
 public static let current = "0.49.0"
}
