import Foundation

/// 通用工具函数
public enum Utils {
 /// 将值转为显示字符串
 public static func formatValue(_ value: Any) -> String {
 if let s = value as? String {
 return s
 }
 if let b = value as? Bool {
 return b ? "true" : "false"
 }
 return "\(value)"
 }

 /// 移除字符串两端引号
 public static func stripQuotes(_ s: String) -> String {
 guard s.count >= 2 else { return s }
 if s.hasPrefix("\"") && s.hasSuffix("\"") {
 return String(s.dropFirst().dropLast())
 }
 return s
 }
}
