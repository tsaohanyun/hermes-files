#!/bin/bash
# 自动生成文件并推送到GitHub
# 用法: ./generate-and-push.sh <目标文件路径> <文件内容>
# 示例: ./generate-and-push.sh html/test.html "<html>...</html>"

set -e

# 检查参数
if [ $# -lt 2 ]; then
    echo "用法: $0 <目标文件路径> <文件内容>"
    echo "示例: $0 html/test.html '<html>内容</html>'"
    exit 1
fi

TARGET_PATH="$1"
FILE_CONTENT="$2"
REPO_DIR="/home/agentuser/hermes-files"
FULL_PATH="$REPO_DIR/$TARGET_PATH"

# 确保目标目录存在
TARGET_DIR=$(dirname "$FULL_PATH")
mkdir -p "$TARGET_DIR"

# 写入文件内容
echo "$FILE_CONTENT" > "$FULL_PATH"
echo "[信息] 文件已生成: $FULL_PATH"

# 切换到仓库目录并推送
cd "$REPO_DIR"
bash git-push.sh "自动生成文件: $TARGET_PATH"

echo "[完成] 文件已推送到GitHub"