FROM ghcr.io/hqzing/dockerharmony:latest

COPY build.sh ./
COPY .zshrc /root/.zshrc

RUN ./build.sh && rm build.sh

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# brew shellenv 变量
ENV PATH="/storage/Users/currentUser/.harmonybrew/bin:/storage/Users/currentUser/.harmonybrew/sbin:${PATH}"
ENV HOMEBREW_PREFIX="/storage/Users/currentUser/.harmonybrew"
ENV HOMEBREW_CELLAR="/storage/Users/currentUser/.harmonybrew/Cellar"
ENV HOMEBREW_REPOSITORY="/storage/Users/currentUser/.harmonybrew/Homebrew"
ENV INFOPATH="/storage/Users/currentUser/.harmonybrew/share/info"

# 全局禁用 api 模式，让 Homebrew 始终处于纯 tap 模式
ENV HOMEBREW_NO_INSTALL_FROM_API=1

# 全局禁用自动升级
ENV HOMEBREW_NO_AUTO_UPDATE=1

# 默认启用 bottle 自动签名
ENV HOMEBREW_OHOS_BOTTLE_BINARY_SIGN=1

CMD ["/bin/sh"]
