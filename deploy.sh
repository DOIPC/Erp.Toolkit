#!/bin/bash
set -e

# ==================== 配置区域 ====================
NETWORK="my-network"
COMMON_DB_PASSWORD="sasa"

# PostgreSQL
PG_CONTAINER="Postgres"
PG_IMAGE="postgres:16"
PG_USER="postgres"
PG_PASSWORD="${COMMON_DB_PASSWORD}"
PG_VOLUME_HOST="$HOME/docker-volumes/postgres_data"
PG_VOLUME_CONTAINER="/var/lib/postgresql/data"
PG_PORT_HOST="5432"
PG_PORT_CONTAINER="5432"
PG_DB_NAME="erp"

# MySQL/MariaDB
MYSQL_CONTAINER="Mariadb"
MYSQL_IMAGE="mariadb:lts-jammy"
MYSQL_ROOT_PASSWORD="${COMMON_DB_PASSWORD}"
MYSQL_VOLUME_HOST="$HOME/docker-volumes/mariadb"
MYSQL_VOLUME_CONTAINER="/var/lib/mysql"
MYSQL_PORT_HOST="3306"
MYSQL_PORT_CONTAINER="3306"
MYSQL_DB_NAME="erp"

# SQL Server
MSSQL_CONTAINER="SqlServer"
MSSQL_IMAGE="mcr.microsoft.com/mssql/server:2022-latest"
MSSQL_SA_PASSWORD="sasa@123456"
MSSQL_VOLUME_HOST="$HOME/docker-volumes/sqlserver"
MSSQL_VOLUME_CONTAINER="/var/opt/mssql"
MSSQL_PORT_HOST="1433"
MSSQL_PORT_CONTAINER="1433"
MSSQL_DB_NAME="erp"

# WebAPI
API_CONTAINER="Erp.WebAPI"
API_IMAGE="doipc/erpwebapi:latest"
UPLOAD_HOST_DIR="$HOME/docker-volumes/appupload"
API_VOLUME="${UPLOAD_HOST_DIR}:/userData"
API_HOST_PORT="80"
API_CONTAINER_PORT="8080"
# =================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "========================================="
echo "  Erp 2.0 WebAPI 全栈依赖一键部署"
echo "  支持: PostgreSQL / MySQL / SQL Server"
echo "========================================="

# ---- 1. 创建网络 ----
echo -e "${YELLOW}[1/10] 创建 Docker 网络: ${NETWORK} ...${NC}"
if docker network inspect ${NETWORK} >/dev/null 2>&1; then
    echo -e "  ℹ️  网络 ${NETWORK} 已存在，跳过创建"
else
    docker network create ${NETWORK}
    echo -e "  ${GREEN}✅ 网络 ${NETWORK} 创建成功${NC}"
fi

# ---- 2. 选择数据库类型 ----
echo -e "${YELLOW}[2/10] 请选择要部署的数据库类型（30秒内无输入默认选择 PostgreSQL）${NC}"
echo "  1) PostgreSQL (默认)"
echo "  2) MySQL/MariaDB"
echo "  3) SQL Server"
read -t 30 -p "请输入选项 [1-3]: " DB_CHOICE || true

if [ -z "$DB_CHOICE" ]; then
    DB_CHOICE=1
    echo -e "${YELLOW}  ⏰ 超时未输入，自动选择 PostgreSQL${NC}"
fi

case $DB_CHOICE in
    1)
        DB_TYPE="postgres"
        DB_CONTAINER="$PG_CONTAINER"
        DB_IMAGE="$PG_IMAGE"
        DB_PORT_HOST="$PG_PORT_HOST"
        DB_PORT_CONTAINER="$PG_PORT_CONTAINER"
        DB_VOLUME_HOST="$PG_VOLUME_HOST"
        DB_VOLUME_CONTAINER="$PG_VOLUME_CONTAINER"
        DB_PROVIDER="PostgreSql"
        DB_CONNECTION_STRING="Host=${DB_CONTAINER};Port=${DB_PORT_CONTAINER};Database=${PG_DB_NAME};Username=${PG_USER};Password=${PG_PASSWORD}"
        DB_ENV=(
            -e "POSTGRES_USER=${PG_USER}"
            -e "POSTGRES_PASSWORD=${PG_PASSWORD}"
            -e "POSTGRES_DB=${PG_DB_NAME}"
        )
        ;;
    2)
        DB_TYPE="mysql"
        DB_CONTAINER="$MYSQL_CONTAINER"
        DB_IMAGE="$MYSQL_IMAGE"
        DB_PORT_HOST="$MYSQL_PORT_HOST"
        DB_PORT_CONTAINER="$MYSQL_PORT_CONTAINER"
        DB_VOLUME_HOST="$MYSQL_VOLUME_HOST"
        DB_VOLUME_CONTAINER="$MYSQL_VOLUME_CONTAINER"
        DB_PROVIDER="MySql"
        DB_CONNECTION_STRING="server=${DB_CONTAINER};port=${DB_PORT_CONTAINER};user=root;password=${MYSQL_ROOT_PASSWORD};database=${MYSQL_DB_NAME}"
        DB_ENV=(
            -e "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}"
            -e "MYSQL_DATABASE=${MYSQL_DB_NAME}"
        )
        ;;
    3)
        DB_TYPE="sqlserver"
        DB_CONTAINER="$MSSQL_CONTAINER"
        DB_IMAGE="$MSSQL_IMAGE"
        DB_PORT_HOST="$MSSQL_PORT_HOST"
        DB_PORT_CONTAINER="$MSSQL_PORT_CONTAINER"
        DB_VOLUME_HOST="$MSSQL_VOLUME_HOST"
        DB_VOLUME_CONTAINER="$MSSQL_VOLUME_CONTAINER"
        DB_PROVIDER="SqlServer"
        DB_CONNECTION_STRING="Server=${DB_CONTAINER},${DB_PORT_CONTAINER};Database=${MSSQL_DB_NAME};User Id=sa;Password=${MSSQL_SA_PASSWORD};TrustServerCertificate=True;"
        DB_ENV=(
            -e "ACCEPT_EULA=Y"
            -e "SA_PASSWORD=${MSSQL_SA_PASSWORD}"
            -e "MSSQL_PID=Express"
        )
        ;;
    *)
        echo -e "${RED}❌ 无效选项，退出脚本${NC}"
        exit 1
        ;;
esac

echo -e "  ${GREEN}✅ 选择数据库: ${DB_TYPE} (容器: ${DB_CONTAINER})${NC}"

# ---- 3. 询问是否删除原有数据 ----
echo -e "${YELLOW}[3/10] 是否删除原有数据库数据？${NC}"
echo "  ⚠️  若选择删除，将清除数据卷目录 ${DB_VOLUME_HOST} 中的所有数据，且不可恢复。"
echo "  默认保留（不删除），30秒内无输入自动保留。"
read -t 30 -p "是否删除数据? [y/N]: " DELETE_INPUT || true

DELETE_DATA=false
if [ -n "$DELETE_INPUT" ]; then
    case "$DELETE_INPUT" in
        [yY]|[yY][eE][sS])
            DELETE_DATA=true
            ;;
        *)
            DELETE_DATA=false
            ;;
    esac
fi

if [ "$DELETE_DATA" = true ]; then
    echo -e "  ${RED}⚠️  已选择删除数据，稍后将清除数据卷目录。${NC}"
else
    echo -e "  ${GREEN}✅ 保留数据卷目录。${NC}"
fi

# ---- 4. 清理旧数据库容器及数据卷 ----
echo -e "${YELLOW}[4/10] 清理旧的 ${DB_CONTAINER} 容器及数据卷...${NC}"
OLD_DB=$(docker ps -a -q -f name=^${DB_CONTAINER}$)
if [ -n "$OLD_DB" ]; then
    echo "  → 发现旧容器 (ID: ${OLD_DB})，正在停止并删除..."
    docker stop ${OLD_DB} 2>/dev/null || true
    docker rm ${OLD_DB} 2>/dev/null || true
    echo -e "  ${GREEN}✅ 旧 ${DB_CONTAINER} 容器已删除${NC}"
else
    echo -e "  ℹ️  未找到名为 ${DB_CONTAINER} 的容器"
fi

# 根据选择处理数据卷目录（含权限处理）
if [ "$DELETE_DATA" = true ]; then
    if [ -d "${DB_VOLUME_HOST}" ]; then
        if [ -w "${DB_VOLUME_HOST}" ]; then
            # 当前用户有写权限，直接删除
            echo "  → 删除数据卷目录: ${DB_VOLUME_HOST}"
            rm -rf "${DB_VOLUME_HOST}"
            echo -e "  ${GREEN}✅ 数据卷已删除${NC}"
        else
            # 当前用户无写权限，尝试使用 sudo 删除
            echo -e "  ${YELLOW}  ⚠️ 当前用户对 ${DB_VOLUME_HOST} 无写权限，尝试使用 sudo 删除...${NC}"
            sudo rm -rf "${DB_VOLUME_HOST}"
            # 验证是否删除成功
            if [ -d "${DB_VOLUME_HOST}" ]; then
                echo -e "  ${RED}❌ sudo 删除失败，目录仍然存在。请手动处理。${NC}"
                exit 1
            else
                echo -e "  ${GREEN}✅ 数据卷已通过 sudo 删除${NC}"
            fi
        fi
    else
        echo -e "  ℹ️  数据卷目录不存在，无需删除"
    fi
else
    echo -e "  ${GREEN}✅ 保留数据卷（${DB_VOLUME_HOST}）${NC}"
fi

# ---- 5. 创建数据目录 ----
echo -e "${YELLOW}[5/10] 创建数据库数据目录...${NC}"
mkdir -p "${DB_VOLUME_HOST}"
echo -e "  ${GREEN}✅ 数据目录已准备: ${DB_VOLUME_HOST}${NC}"

# ---- 6. 启动数据库容器 ----
echo -e "${YELLOW}[6/10] 启动 ${DB_CONTAINER} 容器...${NC}"
docker run --name ${DB_CONTAINER} \
    --network ${NETWORK} \
    "${DB_ENV[@]}" \
    -v "${DB_VOLUME_HOST}:${DB_VOLUME_CONTAINER}" \
    -p ${DB_PORT_HOST}:${DB_PORT_CONTAINER} \
    -d ${DB_IMAGE}
echo -e "  ${GREEN}✅ ${DB_CONTAINER} 已启动（端口: ${DB_PORT_HOST}）${NC}"

# ---- 7. 等待数据库就绪 ----
echo -e "  ⏳ 等待数据库就绪..."
case $DB_TYPE in
    postgres)
        for i in {1..30}; do
            if docker exec ${DB_CONTAINER} pg_isready -U ${PG_USER} >/dev/null 2>&1; then
                echo -e "  ${GREEN}✅ PostgreSQL 已就绪${NC}"
                break
            fi
            sleep 2
        done
        ;;
    mysql)
        for i in {1..30}; do
            if docker exec ${DB_CONTAINER} mysqladmin ping -h localhost -uroot -p${MYSQL_ROOT_PASSWORD} --silent >/dev/null 2>&1; then
                echo -e "  ${GREEN}✅ MySQL/MariaDB 已就绪${NC}"
                break
            fi
            sleep 2
        done
        ;;
    sqlserver)
        echo -e "  ⏳ SQL Server 启动中，可能需要 20-30 秒..."
        sleep 30
        echo -e "  ℹ️  尝试创建数据库 ${MSSQL_DB_NAME}..."
        docker exec ${DB_CONTAINER} /opt/mssql-tools/bin/sqlcmd \
            -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" \
            -Q "IF DB_ID('${MSSQL_DB_NAME}') IS NULL CREATE DATABASE [${MSSQL_DB_NAME}]" \
            >/dev/null 2>&1 || echo -e "  ${YELLOW}⚠️  自动创建数据库失败，请稍后手动创建或确认容器内 sqlcmd 路径${NC}"
        ;;
esac

# ---- 8. 清理旧 WebAPI 容器 ----
echo -e "${YELLOW}[8/10] 清理旧的 WebAPI 容器...${NC}"
OLD_API=$(docker ps -a -q -f name=^${API_CONTAINER}$)
if [ -n "$OLD_API" ]; then
    echo "  → 发现旧容器 (ID: ${OLD_API})，正在停止并删除..."
    docker stop ${OLD_API} 2>/dev/null || true
    docker rm ${OLD_API} 2>/dev/null || true
    echo -e "  ${GREEN}✅ 旧 WebAPI 容器已删除${NC}"
else
    echo -e "  ℹ️  未找到名为 ${API_CONTAINER} 的容器"
fi

# ---- 9. 拉取最新 WebAPI 镜像 ----
echo -e "${YELLOW}[9/10] 拉取最新 WebAPI 镜像: ${API_IMAGE} ...${NC}"
docker pull ${API_IMAGE}
echo -e "  ${GREEN}✅ WebAPI 镜像拉取完成${NC}"
docker image prune -f

# ---- 10. 准备上传目录并启动 WebAPI ----
echo -e "${YELLOW}[10/10] 准备宿主机上传目录并启动 WebAPI...${NC}"
mkdir -p "${UPLOAD_HOST_DIR}"
chmod 755 "${UPLOAD_HOST_DIR}"
echo -e "  ${GREEN}✅ 目录权限已设置（755）${NC}"

echo -e "  ⏳ 生成安全的 JWT 密钥..."
if command -v openssl &> /dev/null; then
    JWT_SIGN_KEY=$(openssl rand -base64 32)
elif command -v python3 &> /dev/null; then
    JWT_SIGN_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
else
    echo -e "  ${RED}❌ 错误：未找到 openssl 或 python3，无法生成随机密钥。${NC}"
    exit 1
fi
echo -e "  ${GREEN}✅ JWT 密钥已生成（长度: ${#JWT_SIGN_KEY} 字符）${NC}"

docker run --name ${API_CONTAINER} \
    --network ${NETWORK} \
    --user $(id -u):$(id -g) \
    -v ${API_VOLUME} \
    -p ${API_HOST_PORT}:${API_CONTAINER_PORT} \
    -e "Database__Provider=${DB_PROVIDER}" \
    -e "ConnectionStrings__${DB_PROVIDER}=${DB_CONNECTION_STRING}" \
    -e "AUTO_MIGRATE=true" \
    -e "Authentication__Jwt__Sign=${JWT_SIGN_KEY}" \
    -d ${API_IMAGE}

if [ $? -eq 0 ]; then

    # ---------- 获取宿主机局域网 IP ----------
    # 优先使用默认路由的 src 地址，避免取到 docker 网桥 IP
    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    # 如果获取失败，退回使用 hostname -I 的第一个地址
    if [ -z "$HOST_IP" ]; then
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    echo "========================================="
    echo -e "  ${GREEN}✅ 全部部署成功！${NC}"
    echo "  ● 网络: ${NETWORK}"
    echo "  ● 数据库: ${DB_TYPE} (容器 ${DB_CONTAINER}，端口 ${DB_PORT_HOST}，数据目录 ${DB_VOLUME_HOST})"
    echo "  ● WebAPI: 容器 ${API_CONTAINER}"
    echo "      - 本机访问:        http://localhost:${API_HOST_PORT}"
    if [ -n "$HOST_IP" ]; then
        echo "      - 局域网/对外IP:   http://${HOST_IP}:${API_HOST_PORT}"
    else
        echo "      - 未获取到宿主机 IP，请手动检查网络配置"
    fi
    echo "  ● 上传目录: ${UPLOAD_HOST_DIR}（挂载到容器内 /userData）"
    echo "  ● 容器以用户 $(id -u):$(id -g) 运行，因此拥有目录写入权限"
    echo "  ● JWT 密钥: 已注入（未显示）"
    if [ "$DB_TYPE" = "mysql" ]; then
        echo "  💡 可选的 phpMyAdmin 管理界面（如需要，请手动执行）："
        echo "     docker run --name phpMyAdmin --network=${NETWORK} -e PMA_HOST=${DB_CONTAINER} -e PMA_PORT=${DB_PORT_CONTAINER} -p 8081:80 -d phpmyadmin:latest"
    fi
    echo "========================================="
    echo "  查看日志:"
    echo "    docker logs -f ${DB_CONTAINER}"
    echo "    docker logs -f ${API_CONTAINER}"
    echo "  进入容器:"
    echo "    docker exec -it ${API_CONTAINER} /bin/bash"
else
    echo -e "  ${RED}❌ WebAPI 启动失败，请检查错误信息。${NC}"
    exit 1
fi