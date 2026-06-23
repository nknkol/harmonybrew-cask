# Formula 编写规范

## 准入规则

- **必须开源**：软件必须是开源软件
- **必须从源码构建**：禁止提交预编译二进制文件作为 formula 的 url。预编译包应通过 CI 生成 bottle
- **代码源必须是官方**：不能使用第三方 fork 版本。如需补丁，通过 `patch` 块引入
- **资源来源**：`resource` 块必须指向官方、版本号固定的 release。禁止用 `master` 分支

## 目录结构

```
├── Formula/             # Ruby 配方文件（平铺，无子目录）
│   ├── binary-sign-tool.rb
│   └── reasonix.rb
├── patches/
│   └── <formula>/       # 每个 formula 一个子目录
│       └── 0001-xxx.patch
├── scripts/
│   └── build-bottle.sh  # CI 通用构建脚本
└── ci-runner/
    └── build.sh          # Docker 初始化脚本
```

## 配方编写

### 命名
- 文件名：`<name>.rb`，全小写，连字符分隔
- 类名：驼峰格式 `BinarySignTool`

### 必填字段
- `desc` — 一行描述
- `homepage` — 项目主页
- `url` — 稳定版本下载链接
- `sha256` — 通过 `brew fetch --build-from-source` 获取
- `bottle do` — 必须包含 `root_url`
- `license` — SPDX 格式
- `test do` — 冒烟测试

### 补丁规范
- 补丁统一放在 `patches/<formula>/` 下
- 命名：`0001-描述.patch`（序号 + 简短描述）
- 生成方法：
  ```zsh
  # 下载两份源码
  curl -L -o a.tar.gz <官方 url>
  gunzip a.tar.gz && tar xf a.tar
  tar xf a.tar
  mv a a_clean
  cp -r a_clean a_mod
  # 修改 a_mod...
  diff -ruN a_clean a_mod > 0001-xxx.patch
  ```
- 在 formula 中引用：
  ```ruby
  patch do
    file "patches/<formula>/0001-xxx.patch"
  end
  ```

### 依赖声明
- 同一 tap 的 formula：`depends_on "binary-sign-tool"`
- 系统构建工具：`depends_on "make" => :build`
- 第三方库（无 formula）：`resource` 块

### bottle
- 每个 formula 必须声明 `root_url`
- release tag 格式：`bottles/<formula>`（一个软件一个 Release）
- 瓶子在 CI 中自动生成并上传

## 提交规范

### Commit Message
| 场景 | 格式 | 示例 |
|------|------|------|
| 新增 | `<formula> <version> (new formula)` | `binary-sign-tool 1.0.0 (new formula)` |
| 版本升级 | `<formula> <version>` | `reasonix 2.0.0` |
| 修复 | `<formula>: <action>` | `binary-sign-tool: fix build` |

### 标签
- 触发 CI 构建 bottle：`bottle/<formula>/<version>`
