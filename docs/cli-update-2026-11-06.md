# CLI 配方更新：2026-11-06

| 配方 | 当前版本 | 保留的历史配方 |
| --- | --- | --- |
| antigravity (`agy`) | 1.5.2 | `antigravity@1.4.2` |
| claude-code | 2.1.318 | `claude-code@2.1.292` |
| codex | 0.167.0 | `codex@0.162.1`（revision 1） |

版本来源：

- [Antigravity 1.5.2](https://github.com/google-antigravity/antigravity-cli/releases/tag/1.5.2)
- [Claude 2.1.318 manifest](https://downloads.claude.ai/claude-code-releases/2.1.318/manifest.json)；更新时 `latest` 为 2.1.318，`stable` 为 2.1.311，沿用最新版通道。
- [Codex 0.167.0](https://github.com/openai/codex/releases/tag/rust-v0.167.0)

历史配方为 keg-only，保留旧版本 URL、源码哈希及适用的补丁，可从源码安装。
历史配方未声明不存在的版本化瓶子；原有非版本化 Release 中的历史瓶子继续保留。
Codex 0.162.1 使用独立冻结的 `patch-harmonyos-0.162.1.rb`。

本次复用 loh 中的 `codex-bottle2`（`harmonybrew-ci:local`），通过
`scripts/build-bottle.sh` 本地构建、签名、打包和测试。容器中旧 tap 指向另一个
工作区，已保留旧目录并将 tap 指向 `/workspace`。下载缓存使用已核对上游
SHA-256 的原始文件。

验证结果：

- 三个配方的源码安装、bottle、postinstall 和 `brew test` 均通过。
- 宿主在仓库产物目录中解压瓶子，agy、Claude 的版本和帮助命令通过。
- Codex 主程序及新增 exec-server 的非 PTY 设置协议、stdout/stderr、退出码 7
  均通过；守护进程启动、包复制、复制后的两个入口及停止测试通过。
- Codex 的 rg、原生 zsh 包装器及 code-mode-host 帮助检查通过。
- 补丁拒绝重复应用且不改写输入。Codex 两个入口均有独立的完整二进制哈希、
  ELF 布局及指令校验；Claude 保留旧签名并增加 2.1.318 的五处特征校验。
- 本机未执行 install、upgrade、link 或 postinstall；测试使用独立私有临时目录。

瓶子 SHA-256：

```text
5aac6183d80e866f17a85b189f858f8dbc976d7724ab3b36014bad7097588dda  antigravity-1.5.2.arm64_ohos.bottle.tar.gz
2230fa2e7af411145442b138697277d5b09d718ceb62f436f9b4d97faf0e056b  claude-code-2.1.318.arm64_ohos.bottle.tar.gz
a94d6841168f94c5b06144deba6d83315956ba000fe2aa36c79b6d42565c436f  codex-0.167.0.arm64_ohos.bottle.tar.gz
```

发布使用 `gh release upload` 向现有 `bottles/antigravity`、`bottles/claude-code`、
`bottles/codex` Release 追加新瓶子和 JSON。不重建 Release，不推送 `bottles/**`
标签，不调用 GitHub Actions。构建日志和宿主验证日志位于本地
`artifacts/cli-update-20261106/`。
