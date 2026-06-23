# Formula 编写规范

## 一、Homebrew 基础要求

以下内容必须遵守，否则无法通过审计：

1. **开源软件**：软件必须是开源软件
2. **从源码构建**：`url` 必须是官方源码发布包，禁止直接下载预编译二进制
3. **官方源**：源码必须来自软件官方，不能使用第三方 fork
4. **License**：必须声明 SPDX 格式的许可证
5. **Test**：必须提供 `test do` 冒烟测试
6. **Stable URL**：`url` 和 `resource` 必须是固定版本号或 tag，禁止用 `master` 分支
7. **Commit Message** 规范：
   | 场景 | 格式 |
   |------|------|
   | 新增 | `<formula> <version> (new formula)` |
   | 升级 | `<formula> <version>` |
   | 修复 | `<formula>: <action>` |

## 二、本仓库额外规范

### 2.1 闭源软件

闭源软件无法从上游源码构建，按以下方式处理：

- 闭源二进制包**视为源代码**
- `url` 指向闭源包的下载地址（无需纠结"源码"来源）
- `install` 中直接安装二进制
- `post_install` 中调用 `binary-sign-tool` 对二进制进行签名
- 签名后用户即可正常运行（鸿蒙要求所有二进制签名）
- **不声明** `depends_on "binary-sign-tool"` — 签名在本地完成，不是运行时依赖

```ruby
class SomeClosedTool < Formula
  desc "闭源工具"
  url "https://vendor.example/releases/tool-arm64.tar.gz"
  sha256 "<fill>"
  version "1.0.0"

  bottle do
    root_url "https://github.com/<user>/<repo>/releases/download/bottles%2Fsome-closed-tool"
  end

  def install
    bin.install "tool"
  end

  def post_install
    system "binary-sign-tool-fix", "sign",
           "-inFile", bin/"tool",
           "-outFile", bin/"tool",
           "-selfSign", "1"
  end
end
```

### 2.2 预编译开源软件

- 同上处理，因为上游提供预编译二进制
- 签名在 `post_install` 中完成

### 2.3 源码编译软件

- `url` 指向官方源码
- 如需补丁，放在 `patches/<formula>/` 下，通过 `patch` 块引用
- 编译时 lld 已注入签名，无需额外签名步骤
- 如需要额外依赖：`depends_on`

### 2.4 CI 签名策略

- CI 不负责签名
- 签名由 formula 自身的 `post_install` 完成
- `build-bottle.sh` 中已移除签名步骤
- CI 构建瓶子 → 用户安装瓶子时 `post_install` 自动签名

## 三、补丁规范

- 补丁统一放在 `patches/<formula>/` 下
- 命名：`0001-简短描述.patch`
- 生成方法：下载两份源码 → 修改一份 → `diff -ruN a b > patch`
- 在 formula 中引用：
  ```ruby
  patch do
    file "patches/<formula>/0001-xxx.patch"
  end
  ```
- 需要 `depends_on "gpatch" => :build` 确保 GNU patch

## 四、bottle 规范

- 每个 formula 必须声明 `root_url`
- 格式：`https://github.com/<user>/<repo>/releases/download/bottles%2F<formula>`
- 一个软件一个 Release：`bottles/<formula>`
- 多版本独立 Release：`bottles/<formula>@1.0`
- Release 由 CI 自动管理，禁止手动操作

## 五、依赖声明

- 同一 tap 的 formula：`depends_on "xxx"`
- 构建工具：`depends_on "make" => :build`
- 第三方库（无 formula）：`resource` 块，URL 必须锁定版本
- 需打补丁时：`depends_on "gpatch" => :build`

## 六、目录结构

```
├── Formula/             # 平铺，无子目录
│   └── <name>.rb
├── patches/
│   └── <formula>/
│       └── 0001-xxx.patch
├── scripts/
│   └── build-bottle.sh
├── ci-runner/
│   └── build.sh
└── docs/
```
