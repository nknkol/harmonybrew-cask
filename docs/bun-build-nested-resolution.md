# bun build 嵌套依赖分析

## 测试结论

1. `bun build` 始终跟进快捷方式到缓存——`--preserve-symlinks` 无效（仅 bun run 支持）
2. 缓存目录里无嵌套 `node_modules/` 快捷方式
3. `BUN_INSTALL_GLOBAL_STORE=1` + 删锁文件 + 删node_modules → 仍无嵌套（仅安装了4个包，0嵌套）
4. 手动在缓存目录建嵌套快捷方式 → 依赖解析通过

## 上游对比

### 上游配方
- 用 `bun run build:release:local`（和我们一样的底层命令）
- 用 bottles（预编译），从不从源码构建
- 无任何环境变量设置

### 上游 CI
- `.buildkite/Dockerfile:215` → `BUN_INSTALL_CACHE=/var/lib/buildkite-agent/cache/bun`（持久化缓存）
- 首次构建生成锁文件+嵌套快捷方式，后续构建复用
- 每次构建共享同一缓存目录

### 上游源代码
- `global_virtual_store=false` （和这里一样默认关闭）
- `preserve_symlinks` resolver代码相同
- 无任何特殊构建配置

## 根本差异

| | 上游 CI | 这里 |
|------|---------|------|
| 缓存 | 持久化（跨构建保留） | 每次全新 |
| 嵌套快捷方式 | 首次构建创建，后续复用 | 永不被创建 |
| bun build | 跟进缓存 → 找到嵌套依赖 | 跟进缓存 → 找不到 |

上游能过是因为 CI 的持久化缓存里已经有历次构建积累的嵌套快捷方式——第一次构建（无`--frozen-lockfile`）创建了它们，构建脚本不会清理缓存。
