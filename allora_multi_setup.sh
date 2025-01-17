#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 函数定义
print_message() {
  echo -e "${GREEN}$1${NC}"
}

print_warning() {
  echo -e "${YELLOW}$1${NC}"
}

print_error() {
  echo -e "${RED}$1${NC}"
}

print_error "如果您对本工具有任何疑问，欢迎到 https://t.me/brotherblockchaingroup交流。"
print_error "========================================================================"

# 检查命令是否存在
check_command() {
  if ! command -v $1 &>/dev/null; then
    print_error "$1 未找到。正在安装..."
    return 1
  fi
  return 0
}

# 安装依赖
install_dependencies() {
  print_message "正在安装依赖..."
  sudo apt update && sudo apt upgrade -y
  sudo apt install -y ca-certificates zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev curl git wget make jq build-essential pkg-config lsb-release libssl-dev libreadline-dev libffi-dev gcc screen unzip lz4 python3 python3-pip
}

# 安装 Docker
install_docker() {
  if ! check_command docker; then
    print_message "正在安装 Docker..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    sudo usermod -aG docker $USER
  fi
}

# 安装 Docker Compose
install_docker_compose() {
  if ! check_command docker-compose; then
    print_message "正在安装 Docker Compose..."
    VER=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
    sudo curl -L "https://github.com/docker/compose/releases/download/${VER}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
  fi
}

# Install Go
install_go() {
  if ! check_command go; then
    print_message "正在安装 Go..."
    sudo rm -rf /usr/local/go
    curl -L https://go.dev/dl/go1.22.4.linux-amd64.tar.gz | sudo tar -xzf - -C /usr/local
    echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> $HOME/.bash_profile
    echo 'export PATH=$PATH:$(go env GOPATH)/bin' >> $HOME/.bash_profile
    source .bash_profile
    go version
  fi
}

# 创建 docker-compose.yml
create_docker_compose() {
  local instance_number=$1
  local wallet_seed=$2
  local head_id=$3
  local port_offset=$((instance_number * 10))
  local subnet="172.22.${instance_number}.0/24"

  cat >$HOME/allora-instances/instance-${instance_number}/docker-compose.yml <<EOL
version: '3'

services:
  inference:
    container_name: inference-eth-pred-${instance_number}
    build:
      context: .
    command: python -u /app/app.py
    ports:
      - "$((8000 + port_offset)):8000"
    networks:
      eth-model-local:
        aliases:
          - inference
        ipv4_address: ${subnet%.*}.4
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/inference/ETH"]
      interval: 10s
      timeout: 5s
      retries: 12
    volumes:
      - ./inference-data:/app/data

  updater:
    container_name: updater-eth-pred-${instance_number}
    build: .
    environment:
      - INFERENCE_API_ADDRESS=http://inference:8000
    command: >
      sh -c "
      while true; do
        python -u /app/update_app.py;
        sleep 24h;
      done
      "
    depends_on:
      inference:
        condition: service_healthy
    networks:
      eth-model-local:
        aliases:
          - updater
        ipv4_address: ${subnet%.*}.5

  worker:
    container_name: worker-eth-pred-${instance_number}
    environment:
      - INFERENCE_API_ADDRESS=http://inference:8000
      - HOME=/data
    build:
      context: .
      dockerfile: Dockerfile_b7s
    entrypoint:
      - "/bin/bash"
      - "-c"
      - |
        if [ ! -f /data/keys/priv.bin ]; then
          echo "Generating new private keys..."
          mkdir -p /data/keys
          cd /data/keys
          allora-keys
        fi
        allora-node --role=worker --peer-db=/data/peerdb --function-db=/data/function-db \
          --runtime-path=/app/runtime --runtime-cli=bls-runtime --workspace=/data/workspace \
          --private-key=/data/keys/priv.bin --log-level=debug --port=$((9011 + port_offset)) \
          --boot-nodes=/ip4/${subnet%.*}.100/tcp/$((9010 + port_offset))/p2p/${head_id} \
          --topic=allora-topic-1-worker \
          --allora-chain-key-name=testkey-${instance_number} \
          --allora-chain-restore-mnemonic='${wallet_seed}' \
          --allora-node-rpc-address=https://allora-rpc.edgenet.allora.network/ \
          --allora-chain-topic-id=1
    volumes:
      - ./worker-data:/data
    working_dir: /data
    depends_on:
      - inference
      - head
    networks:
      eth-model-local:
        aliases:
          - worker
        ipv4_address: ${subnet%.*}.10

  head:
    container_name: head-eth-pred-${instance_number}
    image: alloranetwork/allora-inference-base-head:latest
    environment:
      - HOME=/data
    entrypoint:
      - "/bin/bash"
      - "-c"
      - |
        if [ ! -f /data/keys/priv.bin ]; then
          echo "Generating new private keys..."
          mkdir -p /data/keys
          cd /data/keys
          allora-keys
        fi
        allora-node --role=head --peer-db=/data/peerdb --function-db=/data/function-db  \
          --runtime-path=/app/runtime --runtime-cli=bls-runtime --workspace=/data/workspace \
          --private-key=/data/keys/priv.bin --log-level=debug --port=$((9010 + port_offset)) --rest-api=:$((6000 + port_offset))
    ports:
      - "$((6000 + port_offset)):$((6000 + port_offset))"
    volumes:
      - ./head-data:/data
    working_dir: /data
    networks:
      eth-model-local:
        aliases:
          - head
        ipv4_address: ${subnet%.*}.100

networks:
  eth-model-local:
    driver: bridge
    ipam:
      config:
        - subnet: ${subnet}

volumes:
  inference-data:
  worker-data:
  head-data:
EOL
}

# 安装 Allorad
install_allorad() {
  if ! check_command allorad; then
    print_message "正在安装 Allorad..."
    rm -rf allora-chain
    git clone https://github.com/allora-network/allora-chain.git
    cd allora-chain
    make all
    cd ..
  fi
}

# 创建新钱包或通过助记词恢复
wallet_setup() {
  local wallet_name=$1
  local wallet_seed=$2

  echo "1. 使用已经存在的钱包"
  echo "2. 创建一个新钱包"
  read -p "请输入选项 1 or 2: " option

  if [ "$option" == "1" ]; then
    read -p "输入您的钱包助记词: " wallet_seed
    allorad keys add testkey --recover <<< "$wallet_seed"
  else
    allorad keys add testkey
  fi
}


# 设置单个实例
setup_instance() {
  local instance_number=$1
  local wallet_seed=$2

  print_message "正在设置实例 #${instance_number}..."

  # 创建实例目录
  mkdir -p allora-instances/instance-${instance_number}
  cd allora-instances/instance-${instance_number}

  # 克隆仓库
  git clone https://github.com/allora-network/basic-coin-prediction-node .

  # 创建必要的目录
  mkdir -p worker-data head-data
  sudo chmod -R 777 worker-data head-data

  # 生成密钥
  sudo docker run -it --entrypoint=bash -v ./head-data:/data alloranetwork/allora-inference-base:latest -c "mkdir -p /data/keys && (cd /data/keys && allora-keys)"
  sudo docker run -it --entrypoint=bash -v ./worker-data:/data alloranetwork/allora-inference-base:latest -c "mkdir -p /data/keys && (cd /data/keys && allora-keys)"

  head_id=$(cat head-data/keys/identity)

  # 创建 docker-compose.yml
  create_docker_compose "$instance_number" "$wallet_seed" "$head_id"

  # 返回到主目录
  cd ../..
}

# 运行实例
run_instance() {
  local instance_number=$1

  print_message "正在运行实例 #${instance_number}..."
  cd allora-instances/instance-${instance_number}
  docker-compose build
  docker-compose up -d
  cd ../..
}

# 查找当前最大的容器编号
query_container_num() {
  MAX_CONTAINER_NUM=$(docker ps -a --format '{{.Names}}' | grep '^worker-eth-pred-[0-9]*$' | sed 's/worker-eth-pred-//' | sort -n | tail -n 1)
  # 如果没有找到容器，从1开始；否则从下一个数字开始
  if [ -z "$MAX_CONTAINER_NUM" ]; then
      START_NUM=1
  else
      START_NUM=$((MAX_CONTAINER_NUM + 1))
  fi
}


# 主函数
main() {
  print_message "开始安装多实例 Allora Network Price Prediction Worker..."

  install_dependencies
  install_go
  install_docker
  install_docker_compose
  install_allorad
  query_container_num

  read -p "请输入要运行的实例数量: " num_instances

  for ((i = 0; i < num_instances; i++)); do
    instance_num=$((START_NUM + i))
    echo "创建钱包${instance_num}"
    wallet_setup
    read -p "请输入实例 #${instance_num} 的钱包助记词: " wallet_seed
    setup_instance $instance_num "$wallet_seed"
  done

  for ((i = 0; i < num_instances; i++)); do
    instance_num=$((START_NUM + i))
    run_instance $instance_num
  done

  print_message "所有实例安装完成！"
  print_warning "请检查 docker 容器状态："
  docker ps

  print_message "你可以使用以下命令检查各个节点的状态："
  for ((i = 0; i < num_instances; i++)); do
    instance_num=$((START_NUM + i))
    port_offset=$((i * 10))
    echo "实例 #${instance_num}:"
    echo "检查 Worker 节点: curl --location 'http://localhost:$((6000 + port_offset))/api/v1/functions/execute' ..."
    echo "检查 Updater 节点: curl http://localhost:$((8000 + port_offset))/update"
    echo "检查 Inference 节点: curl http://localhost:$((8000 + port_offset))/inference/ETH"
    echo ""
  done
}

# 运行主函数
main
