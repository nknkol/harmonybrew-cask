# 检查容器环境
echo '=== PATH ==='
docker exec ohosci-builder /bin/sh -c 'echo $PATH' 2>&1

echo '=== which grep ==='
docker exec ohosci-builder /bin/sh -c 'which grep' 2>&1

echo '=== ls /bin/grep ==='
docker exec ohosci-builder ls /bin/grep 2>&1

echo '=== which brew ==='
docker exec ohosci-builder /bin/sh -c 'which brew' 2>&1

echo '=== brew shellenv ==='
docker exec ohosci-builder /bin/sh -c '/storage/Users/currentUser/.harmonybrew/bin/brew shellenv' 2>&1
