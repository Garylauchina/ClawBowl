# iOS Swift 包依赖说明

工程仅依赖 **MarkdownUI**：

- **MarkdownUI**：`https://github.com/gonzalezreal/swift-markdown-ui`，版本 2.4.1

若 Xcode 报 **Missing package product 'MarkdownUI'**，请按顺序操作：

1. 关闭 Xcode。
2. 删除本地包缓存（可选，用于清掉错误状态）：
   ```bash
   rm -rf ~/Library/Caches/org.swift.swiftpm
   rm -rf ~/Library/Developer/Xcode/DerivedData/*/SourcePackages
   ```
3. 重新打开 `ClawBowl.xcodeproj`。
4. 菜单 **File → Packages → Reset Package Caches**。
5. 菜单 **File → Packages → Resolve Package Versions**（需能访问 github.com）。
6. 再执行 **Product → Build**。

若网络无法直连 GitHub，可配置代理或使用镜像后再执行步骤 4–5。
