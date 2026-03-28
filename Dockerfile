# 核心镜像：使用 node-slim 保持轻量
FROM node:22-slim

# 1. 整合系统依赖安装（包含 ffmpeg, jq, tmux 等基础工具）
RUN apt-get update && apt-get install -y --no-install-recommends \
  git \
  python3 \
  python3-pip \
  ca-certificates \
  procps \
  tzdata \
  ffmpeg \
  jq \
  curl \
  wget \
  tmux \
  tar \
  gzip \
  && rm -rf /var/lib/apt/lists/*

# 1.5 下载并安装 GitHub CLI (gh) 二进制包
RUN wget -q https://github.com/cli/cli/releases/download/v2.44.1/gh_2.44.1_linux_amd64.tar.gz -O gh.tar.gz \
  && tar -xzf gh.tar.gz \
  && mv gh_2.44.1_linux_amd64/bin/gh /usr/local/bin/ \
  && rm -rf gh.tar.gz gh_2.44.1_linux_amd64

# 2. 安装 Python 同步依赖（增加 uv 工具）
RUN pip3 install --no-cache-dir --break-system-packages huggingface_hub uv

# 3. 安装核心程序及 NPM 扩展技能
RUN npm install -g \
  openclaw \
  clawhub \
  mcporter \
  @steipete/oracle \
  --registry=https://registry.npmjs.org/ \
  --unsafe-perm=true \
  --foreground-scripts \
  && npm cache clean --force

# 4. 环境变量预设
ENV TZ=Asia/Shanghai \
  PORT=7860 \
  HOME=/root \
  OPENCLAW_TRUST_LOCAL_WS=1 \
  OPENCLAW_SECURITY_STRICT=false \
  NODE_TLS_REJECT_UNAUTHORIZED=0 \
  OPENCLAW_TRUST_PROXY=true \
  NODE_ENV=production

# 5. 同步引擎
RUN cat > /usr/local/bin/sync.py <<'PYEOF'
import os
import re
import sys
import tarfile
from datetime import datetime, timedelta

from huggingface_hub import HfApi, hf_hub_download

api = HfApi()
repo_id = os.getenv("HF_DATASET")
token = os.getenv("HF_TOKEN")
base_dir = "/root"
backup_pattern = re.compile(r"^openclaw-backup-(\d{4}-\d{2}-\d{2})\.tar\.gz$")
max_backups = 3


def restore():
    if not repo_id or not token:
        return

    try:
        files = api.list_repo_files(repo_id=repo_id, repo_type="dataset", token=token)
        now = datetime.now()

        for i in range(5):
            day = (now - timedelta(days=i)).strftime("%Y-%m-%d")
            name = "openclaw-backup-" + day + ".tar.gz"

            if name in files:
                path = hf_hub_download(
                    repo_id=repo_id,
                    filename=name,
                    repo_type="dataset",
                    token=token,
                )
                with tarfile.open(path, "r:gz") as tar:
                    tar.extractall(path=base_dir)
                print("--- [Sync] restore success: " + day + " ---")
                return True
    except Exception as e:
        print("--- [Sync] restore failed: " + str(e) + " ---")


def cleanup_old_backups():
    files = api.list_repo_files(repo_id=repo_id, repo_type="dataset", token=token)
    backup_names = []

    for file_name in files:
        match = backup_pattern.match(file_name)
        if match:
            backup_names.append((match.group(1), file_name))

    backup_names.sort(reverse=True)

    for _, file_name in backup_names[max_backups:]:
        api.delete_file(
            path_in_repo=file_name,
            repo_id=repo_id,
            repo_type="dataset",
            token=token,
        )
        print("--- [Sync] removed old backup: " + file_name + " ---")


def backup():
    if not repo_id or not token:
        return

    name = None

    try:
        target_dir = "/root/.openclaw"
        if not os.path.exists(target_dir):
            return

        day_str = datetime.now().strftime("%Y-%m-%d")
        name = "openclaw-backup-" + day_str + ".tar.gz"

        with tarfile.open(name, "w:gz") as tar:
            tar.add(target_dir, arcname=".openclaw")

        api.upload_file(
            path_or_fileobj=name,
            path_in_repo=name,
            repo_id=repo_id,
            repo_type="dataset",
            token=token,
        )

        cleanup_old_backups()
        print("--- [Sync] backup complete: " + name + " ---")
    except Exception as e:
        print("--- [Sync] backup failed: " + str(e) + " ---")
    finally:
        if name and os.path.exists(name):
            os.remove(name)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "backup":
        backup()
    else:
        restore()
PYEOF

# 6. 最终启动脚本
RUN cat > /usr/local/bin/start-openclaw <<'SHEOF' \
  && chmod +x /usr/local/bin/start-openclaw
#!/bin/bash
set -e

mkdir -p /root/.openclaw
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

python3 /usr/local/bin/sync.py restore || true
find /root/.openclaw -name "*.lock" -delete
chmod 700 /root/.openclaw

CLEAN_BASE=$(echo "$OPENAI_API_BASE" | sed 's|/chat/completions||g' | sed 's|/$||g')
if [[ "$CLEAN_BASE" != */v1 ]]; then
  CLEAN_BASE="$CLEAN_BASE/v1"
fi

if [ ! -f /root/.openclaw/openclaw.json ]; then
  echo "--- [Config] no existing openclaw.json, generating default config ---"
  cat > /root/.openclaw/openclaw.json <<EOF
{
  "models": {
    "providers": {
      "openai": {
        "baseUrl": "$CLEAN_BASE",
        "apiKey": "$OPENAI_API_KEY",
        "api": "openai-completions",
        "models": [
          {
            "id": "$MODEL",
            "name": "OpenAI",
            "contextWindow": 1000000
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openai/gpt-5.4"
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "botToken": "$TELEGRAM_BOT_TOKEN",
      "dmPolicy": "allowlist",
      "allowFrom": ["$TELEGRAM_USER_ID"]
    }
  },
  "gateway": {
    "mode": "local",
    "port": 7860,
    "bind": "custom",
    "customBindHost": "0.0.0.0",
    "trustedProxies": ["0.0.0.0/0"],
    "auth": {
      "mode": "token",
      "token": "$OPENCLAW_GATEWAY_PASSWORD"
    },
    "controlUi": {
      "enabled": true,
      "dangerouslyDisableDeviceAuth": true,
      "allowedOrigins": ["https://kiritoxdone-xy.hf.space"]
    },
    "tools": {
      "deny": ["gateway"]
    }
  }
}
EOF
else
  echo "--- [Config] existing openclaw.json found, keeping restored config ---"
fi

(
  while true; do
    sleep 1800
    python3 /usr/local/bin/sync.py backup || true
  done
) &

echo "--- (System) starting OpenClaw Gateway ---"
export NODE_ENV=production
export OPENCLAW_TRUST_PROXY=true

openclaw gateway run &
GATEWAY_PID=$!

for i in $(seq 1 20); do
sleep 2
openclaw devices approve --latest >/dev/null 2>&1 || true
openclaw status >/dev/null 2>&1 && break
done

wait $GATEWAY_PID
SHEOF

EXPOSE 7860

CMD ["/usr/local/bin/start-openclaw"]
