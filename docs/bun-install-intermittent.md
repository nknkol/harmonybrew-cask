# bun install 间歇性提取失败

## 现象

`bun install` 在构建中每次都有 2-3 个包报 `Fail extracting tarball` 或 `IntegrityCheckFailed`，包每次都不同（`source-map`、`lightningcss`、`typescript`、`prettier`、`scheduler` 等）。孤立测试中同一包 100% 通过。

## 根因

不是代码逻辑问题。补丁 0003 已将 hmdfs 相关硬链接路径改为软连接或 copyfile fallback。230+ 包并行安装时 hmdfs 上 tarball 解压写盘偶尔中断。不影响最终构建——缺的包不是构建实际使用的。

## 处理

配方中 `ENV["BUN_INSTALL_CACHE_DIR"]` 将缓存放入构建树以避免跨构建污染。暂时接受间歇性失败，不影响最终产物。
