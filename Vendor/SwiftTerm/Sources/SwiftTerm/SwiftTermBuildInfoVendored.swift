//
//  SwiftTermBuildInfoVendored.swift
//  SwiftTerm (vendored by Picoterm)
//
//  上游由 SwiftTermBuildInfoPlugin 在构建期生成同名常量；vendored 副本不带
//  git 元数据，这里固化 vendored 基线版本（上游 v1.99.0）。
//

#if !SWIFTTERM_EMBEDDED
enum SwiftTermBuildInfo {
    static let tag = "v1.99.0"
    static let branch = "picoterm-vendored"
    static let version = "1.99.0"
}
#endif
