#!/bin/sh
set -e

# 下载一些命令行工具，并将它们软链接到 /bin 目录中
cd /opt
echo "coreutils 9.11
busybox 1.37.0
grep 3.12
sed 4.10
gawk 5.3.2
tar 1.35
gzip 1.14
diffutils 3.12
patch 2.8
texinfo 7.2
perl 5.42.0
make 4.4.1
vim 9.2.0150
openssh 10.2p1
zsh 5.9
git 2.53.0
ruby 4.0.3
bash 5.3
python 3.14.5" >/tmp/tools.txt
while read -r name ver; do
    curl -fLO https://github.com/Harmonybrew/ohos-$name/releases/download/$ver/$name-$ver-ohos-arm64.tar.gz
done </tmp/tools.txt
ls | grep tar.gz$ | xargs -n 1 tar -zxf
rm -rf *.tar.gz /tmp/tools.txt
ln -sf $(pwd)/*-ohos-arm64/bin/* /bin/

# 下载 ohos-sdk
sdk_download_url="https://cidownload.openharmony.cn/version/Master_Version/ohos-sdk-public_ohos/20260330_020501/version-Master_Version-ohos-sdk-public_ohos-20260330_020501-ohos-sdk-public_ohos.tar.gz"
curl -fSL -o ohos-sdk.tar.gz $sdk_download_url
mkdir /opt/ohos-sdk
tar -zxf ohos-sdk.tar.gz -C /opt/ohos-sdk
rm -f ohos-sdk.tar.gz
cd /opt/ohos-sdk/ohos
busybox unzip -q native-*.zip
busybox unzip -q toolchains-*.zip
rm -f *.zip
cd - >/dev/null

# 把 llvm 里面的命令封装一份放到 /bin 目录下，只封装必要的工具。
# 为了照顾 clang （clang 软链接到其他目录使用会找不到 sysroot），
# 对所有命令统一用这种封装的方案，而非软链接。
essential_tools="clang
clang++
clang-cpp
ld.lld
lldb
llvm-addr2line
llvm-ar
llvm-as
llvm-cfi-verify
llvm-config
llvm-cov
llvm-cxxfilt
llvm-dis
llvm-dwarfdump
llvm-dwp
llvm-lib
llvm-link
llvm-modextract
llvm-nm
llvm-objcopy
llvm-objdump
llvm-profdata
llvm-ranlib
llvm-rc
llvm-readelf
llvm-readobj
llvm-size
llvm-strings
llvm-strip
llvm-symbolizer"
for executable in $essential_tools; do
    cat <<EOF > /bin/$executable
#!/bin/sh
exec /opt/ohos-sdk/ohos/native/llvm/bin/$executable "\$@"
EOF
    chmod 0755 /bin/$executable
done

# 签名工具软链接到 /bin 目录下
ln -s /opt/ohos-sdk/ohos/toolchains/lib/binary-sign-tool /bin/binary-sign-tool

# 对 llvm 进行软链接，生成 cc、gcc、ld、binutils
cd /bin
ln -s clang cc
ln -s clang gcc
ln -s clang++ c++
ln -s clang++ g++
ln -s clang-cpp cpp
ln -s ld.lld ld
ln -s llvm-addr2line addr2line
ln -s llvm-ar ar
ln -s llvm-cxxfilt c++filt
ln -s llvm-nm nm
ln -s llvm-objcopy objcopy
ln -s llvm-objdump objdump
ln -s llvm-ranlib ranlib
ln -s llvm-readelf readelf
ln -s llvm-size size
ln -s llvm-strip strip
cd - >/dev/null

# 安装流水线脚本需要用到的 python 三方库
pip3 install --upgrade pip
pip3 install \
    cryptography \
    requests \
    huaweicloudsdkcore \
    huaweicloudsdkcdn \
    esdk-obs-python

# 安装 homebrew。
# 这里的安装脚本使用 gitcode 代码仓里面的文件，而不是我们自己的 CDN 链接。
# 因为 CDN 里面的文件由 auto-static 流水线上传，而 auto-static 流水线又依赖这个镜像。
# 如果这里使用了 CDN 链接，auto-image 和 auto-static 这两个流水线就会产生循环依赖关系。
export HOMEBREW_NO_INSTALL_FROM_API=1
export PATH=/storage/Users/currentUser/.harmonybrew/bin:$PATH
git clone https://atomgit.com/Harmonybrew/install.git /tmp/install
zsh /tmp/install/install.sh
rm -rf /tmp/install

# 预置 tap
brew tap --force harmonybrew/core

# 把 homebrew 用到的 ruby 三方库进行预安装，
# 之后每次执行 brew test、brew bottle 等命令的时候就无需实时安装
brew install-bundler-gems --groups=bottle,formula_test,tests,livecheck,ast,style,audit

# 清除缓存
rm -rf $(brew --cache)
rm -rf ~/.cache

# 生成常用的 rc 文件
cat <<EOF > /root/.mkshrc
alias ls="ls --color=auto"
alias grep="grep --color=auto"
EOF

cat <<EOF > /root/.bashrc
alias ls="ls --color=auto"
alias grep="grep --color=auto"
EOF

# 实现 ldd 脚本
cat <<'EOF' > /usr/bin/ldd
#!/bin/sh
exec /lib/ld-musl-aarch64.so.1 --list "$@"
EOF
chmod 0755 /usr/bin/ldd

# 许多 Rust 项目会使用到一个叫做 iana-time-zone 的三方库（通常是因为业务代码使用了
# chrono，而 chrono 又级联依赖了 iana-time-zone）。在 OpenHarmony 平台上，该库会通过
# FFI 强行调用系统库 libtime_service_ndk.so 里面的 OH_TimeService_GetTimeZone 符号。
#
# 当前容器环境为精简版 rootfs，并未提供真实的系统环境与 NDK 动态库（且容器内无相关系统服务）。
# 为避免 Rust 项目因缺失依赖或符号无法加载而运行失败，此处做一个 Stub（桩）实现，
# 拦截时区查询并默认返回 "Asia/Shanghai"，确保程序可以正常启动，避免 brew test 测试失败。
ln -s /lib64 /system/lib64
mkdir /system/lib64/ndk
cat << 'EOF' > /tmp/time_service.c
#include <stdint.h>
#include <stdio.h>
uint32_t OH_TimeService_GetTimeZone(char *timeZone, uint32_t len) {
    if (timeZone != 0 && len > 0) {
        snprintf(timeZone, len, "Asia/Shanghai");
    }
    return 0;
}
EOF
clang -shared -fPIC /tmp/time_service.c -o /system/lib64/ndk/libtime_service_ndk.so
rm /tmp/time_service.c

# 补齐一些可能用到的“沙箱目录”（只是路径相同，实际上不是真沙箱目录）
mkdir -p /data/storage/el2/base/files                   # 应用级数据目录
mkdir -p /data/storage/el2/base/cache                   # 应用级缓存目录
mkdir -p /data/storage/el2/base/haps/entry/files        # 模块级数据目录
mkdir -p /data/storage/el2/base/haps/entry/cache        # 模块级缓存目录
