# glibc HarmonyOS 补丁

本目录记录为了让 **glibc 2.38** 能在 HarmonyOS PC（鸿蒙内核）上正确加载
Antigravity CLI（Go + cgo 静态链接 Chromium 组件的二进制）所需的三个源码补丁。

## 背景

鸿蒙内核与标准 Linux 内核有三个不兼容点，导致 vanilla glibc 加载器无法
运行这类二进制：

1. **mmap(PROT_EXEC) 范围限制**：鸿蒙内核对「带执行权限的文件映射」强制要求
   其范围必须完全落在 ELF 的第一个可执行 LOAD 段内。glibc 的 `_dl_map_segments`
   快速路径会一次性 mmap 覆盖全部段（含段间空洞）的范围，且用第一段的
   PROT_EXEC，从而越界 → `EACCES`。

2. **禁止事后 mprotect 加执行权限**：鸿蒙内核禁止对已映射页通过
   `mprotect` 从非执行改为可执行。因此「先 map 再 mprotect 加 EXEC」的
   常规做法也走不通。

3. **未实现的 syscall 直接发 SIGSYS**：鸿蒙内核对未实现的新 syscall
   （rseq、clone3、close_range 等）不是返回 `ENOSYS`，而是直接给进程发
   `SIGSYS`（Bad system call）杀死进程。glibc 针对这些 syscall 的
   ENOSYS 回退逻辑永远走不到。

## 补丁内容（`glibc-harmonyos.patch`，共三处）

| 文件 | 补丁 |
|---|---|
| `elf/dl-map-segments.h` | 全范围先以**不带 EXEC** 映射，再用 `MAP_FIXED` 重新 mmap 第一个可执行段的精确范围恢复 EXEC（MAP_FIXED 重映射在鸿蒙上可行） |
| `sysdeps/unix/sysv/linux/rseq-internal.h` | 完全跳过 rseq syscall，直接标记注册失败 |
| `sysdeps/unix/sysv/linux/clone-internal.c` | 强制走老 `clone` fallback，不尝试 clone3 |

## 构建方式

在 **openEuler 24.03（aarch64 glibc）** 环境（鸿蒙 PC 上通过 `loh` 子系统，
ssh `root@172.16.105.2`）中编译：

```sh
# 1. 安装编译依赖
dnf install -y gcc-c++ bison flex

# 2. 解压 glibc 2.38 源码并应用补丁
tar -xJf glibc-2.38.tar.xz
cd glibc-2.38
patch -p1 < glibc-harmonyos.patch

# 3. configure + 编译
mkdir build && cd build
../glibc-2.38/configure --prefix=/usr --with-headers=/usr/include \
    --disable-werror --disable-nscd
make -j$(nproc)
```

产物（strip 后）：
- `elf/ld.so` → `ld-linux-aarch64.so.1`
- `libc.so` → `libc.so.6`
- `math/libm.so` → `libm.so.6`
- `nptl/libpthread.so` → `libpthread.so.0`
- `dlfcn/libdl.so` → `libdl.so.2`
- `resolv/libresolv.so` → `libresolv.so.2`
- `rt/librt.so` → `librt.so.1`

## 关键结论

- 鸿蒙 ELF/共享库都必须签名（`binary-sign-tool-fix sign -selfSign 1`）。
- 文件需放在非 hmdfs 锁权限的挂载（如 `/data/storage/el2/base/files`），
  或通过 HAP 沙盒权限决定执行权限。
- 符号链接需要实体化（鸿蒙按文件名实体做签名校验）。
