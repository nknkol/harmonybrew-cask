# 诊断 ohosci:1.0 镜像

# 1. 检查基础工具是否存在
docker run --rm ohosci:1.0 ls /bin/grep /bin/readlink /bin/sleep 2>&1

# 2. 检查 Homebrew
docker run --rm ohosci:1.0 ls /storage/Users/currentUser/.harmonybrew/bin/brew 2>&1

# 3. 如果上面都报 No such file，重建镜像
(cd ci-runner && DOCKER_BUILDKIT=0 docker build --no-cache -t ohosci:1.0 .)

# 4. 清理旧容器，用新镜像重建
docker rm -f ohosci-builder 2>/dev/null; sh scripts/local-build.sh
