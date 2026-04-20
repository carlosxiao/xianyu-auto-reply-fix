#!/bin/bash
# 闲鱼管理系统 Docker 镜像构建脚本
# 支持指定版本号、架构、镜像名、推送仓库等参数
#
# 用法:
#   ./build.sh                          # 默认: amd64, latest
#   ./build.sh -v v1.9.4                # 指定版本
#   ./build.sh -v v1.9.4 -a arm64       # 构建 ARM64
#   ./build.sh -v v1.9.4 -a all         # 多架构 (amd64+arm64)
#   ./build.sh -v v1.9.4 -a all -p      # 多架构并推送到仓库
#   ./build.sh -v v1.9.4 -r ghcr.io/user/repo -p

set -e

# ==================== 默认配置 ====================
VERSION=""
PLATFORM="amd64"
IMAGE_NAME="xianyu-auto-reply-fix"
DOCKERFILE="Dockerfile"
PUSH=false
REGISTRY=""

# ==================== 参数解析 ====================
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -v, --version VERSION    版本号标签 (如 v1.9.4)，不指定则从 static/version.txt 读取"
    echo "  -a, --arch  ARCH         目标架构: amd64 | arm64 | all (默认: amd64)"
    echo "  -n, --name  NAME         镜像名称 (默认: xianyu-auto-reply-fix)"
    echo "  -f, --file  DOCKERFILE   Dockerfile 路径 (默认: Dockerfile)"
    echo "  -r, --registry REGISTRY  镜像仓库前缀 (如 ghcr.io/user)"
    echo "  -p, --push               构建后推送到仓库"
    echo "  -h, --help               显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 -v v1.9.4"
    echo "  $0 -v v1.9.4 -a arm64"
    echo "  $0 -v v1.9.4 -a all -r ghcr.io/myuser -p"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version)
            VERSION="$2"; shift 2 ;;
        -a|--arch)
            PLATFORM="$2"; shift 2 ;;
        -n|--name)
            IMAGE_NAME="$2"; shift 2 ;;
        -f|--file)
            DOCKERFILE="$2"; shift 2 ;;
        -r|--registry)
            REGISTRY="$2"; shift 2 ;;
        -p|--push)
            PUSH=true; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "未知参数: $1"; usage; exit 1 ;;
    esac
done

# ==================== 自动读取版本号 ====================
if [ -z "$VERSION" ]; then
    if [ -f "static/version.txt" ]; then
        VERSION=$(tr -d '\r\n' < static/version.txt)
        echo "[INFO] 从 static/version.txt 读取版本: $VERSION"
    else
        VERSION="latest"
        echo "[WARN] 未指定版本且 static/version.txt 不存在，使用 latest"
    fi
fi

# ==================== 校验 ====================
if [ ! -f "$DOCKERFILE" ]; then
    echo "[ERROR] Dockerfile 不存在: $DOCKERFILE"; exit 1
fi

if [ "$PUSH" = true ] && [ -z "$REGISTRY" ]; then
    echo "[ERROR] 推送镜像需要指定仓库地址 (-r/--registry)"
    echo "  示例: $0 -v $VERSION -r ghcr.io/myuser -p"
    exit 1
fi

# ==================== 确定平台 ====================
case "$PLATFORM" in
    amd64)   TARGET_PLATFORMS="linux/amd64" ;;
    arm64)   TARGET_PLATFORMS="linux/arm64" ;;
    all)     TARGET_PLATFORMS="linux/amd64,linux/arm64" ;;
    *)
        echo "[ERROR] 不支持的架构: $PLATFORM (可选: amd64, arm64, all)"; exit 1 ;;
esac

# ==================== 构建镜像名 ====================
if [ -n "$REGISTRY" ]; then
    FULL_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}"
else
    FULL_IMAGE_NAME="${IMAGE_NAME}"
fi

# ==================== 输出配置 ====================
echo "========================================"
echo "  Docker 镜像构建"
echo "========================================"
echo "  镜像:   ${FULL_IMAGE_NAME}:${VERSION}"
if [ "$VERSION" != "latest" ]; then
    echo "  标签:   ${FULL_IMAGE_NAME}:latest"
fi
echo "  架构:   $TARGET_PLATFORMS"
echo "  文件:   $DOCKERFILE"
echo "  推送:   $PUSH"
echo "========================================"
echo ""

# ==================== 检查 Docker =====================
if ! docker info >/dev/null 2>&1; then
    echo "[ERROR] Docker 未运行，请先启动 Docker"; exit 1
fi
echo "[OK] Docker 服务正常"

# ==================== 多架构准备 ====================
NEED_BUILDX=false
if echo "$TARGET_PLATFORMS" | grep -q ","; then
    NEED_BUILDX=true
fi

# 检测本机架构，如果只构建本机架构可以不用 buildx container driver
LOCAL_ARCH=""
case "$(uname -m)" in
    x86_64|amd64)  LOCAL_ARCH="linux/amd64" ;;
    arm64|aarch64) LOCAL_ARCH="linux/arm64" ;;
esac

if [ "$NEED_BUILDX" = false ] && [ "$TARGET_PLATFORMS" = "$LOCAL_ARCH" ]; then
    # 单架构 + 本机架构：直接 docker build 即可，无需 buildx
    USE_BUILDX=false
else
    USE_BUILDX=true
fi

# ==================== buildx 设置 ====================
if [ "$USE_BUILDX" = true ]; then
    echo ""
    echo "[INFO] 多架构或跨平台构建，使用 buildx"

    # 安装 QEMU（跨架构需要）
    if [ "$NEED_BUILDX" = true ]; then
        echo "[INFO] 安装 QEMU 模拟器..."
        docker run --rm --privileged tonistiigi/binfmt --install all >/dev/null 2>&1 && \
            echo "[OK] QEMU 安装成功" || \
            echo "[WARN] QEMU 安装失败，跨架构构建可能出错"
    fi

    # 检查/创建 builder
    BUILDER_NAME="xianyu-builder"
    if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
        echo "[INFO] 创建 buildx builder: $BUILDER_NAME"
        docker buildx create --name "$BUILDER_NAME" --driver docker-container --use --bootstrap \
            --driver-opt network=host >/dev/null 2>&1 || \
        docker buildx create --name "$BUILDER_NAME" --use --bootstrap >/dev/null 2>&1 || \
        { echo "[ERROR] 创建 buildx builder 失败"; exit 1; }
    else
        docker buildx use "$BUILDER_NAME"
        docker buildx inspect --bootstrap >/dev/null 2>&1
    fi
    echo "[OK] buildx builder 就绪"
fi

# ==================== 开始构建 ====================
echo ""
echo "========================================"
echo "  开始构建..."
echo "========================================"

# 构建 tag 参数
TAG_ARGS="-t ${FULL_IMAGE_NAME}:${VERSION}"
if [ "$VERSION" != "latest" ]; then
    TAG_ARGS="$TAG_ARGS -t ${FULL_IMAGE_NAME}:latest"
fi

if [ "$PUSH" = true ]; then
    OUTPUT_FLAG="--push"
elif [ "$USE_BUILDX" = true ]; then
    OUTPUT_FLAG="--load"
    # buildx --load 只支持单架构
    if echo "$TARGET_PLATFORMS" | grep -q ","; then
        echo "[WARN] --load 不支持多架构，将仅加载本机架构 ($LOCAL_ARCH)"
        TARGET_PLATFORMS="$LOCAL_ARCH"
    fi
else
    OUTPUT_FLAG=""
fi

if [ "$USE_BUILDX" = true ]; then
    docker buildx build \
        --platform "$TARGET_PLATFORMS" \
        $TAG_ARGS \
        -f "$DOCKERFILE" \
        $OUTPUT_FLAG \
        .
else
    docker build \
        --platform "$TARGET_PLATFORMS" \
        $TAG_ARGS \
        -f "$DOCKERFILE" \
        .
fi

BUILD_EXIT=$?

# ==================== 结果 ====================
echo ""
if [ $BUILD_EXIT -eq 0 ]; then
    echo "========================================"
    echo "  构建成功!"
    echo "========================================"
    echo "  镜像: ${FULL_IMAGE_NAME}:${VERSION}"
    if [ "$VERSION" != "latest" ]; then
        echo "        ${FULL_IMAGE_NAME}:latest"
    fi
    echo ""
    echo "运行:"
    echo "  docker run -d -p 8090:8090 --name xianyu ${FULL_IMAGE_NAME}:${VERSION}"
    echo ""

    if [ "$PUSH" = true ]; then
        echo "验证多架构:"
        echo "  docker buildx imagetools inspect ${FULL_IMAGE_NAME}:${VERSION}"
    else
        echo "查看本地镜像:"
        echo "  docker images ${FULL_IMAGE_NAME}"
    fi
else
    echo "========================================"
    echo "  构建失败 (exit code: $BUILD_EXIT)"
    echo "========================================"
    exit $BUILD_EXIT
fi
