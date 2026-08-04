#!/usr/bin/env bash
# 通过 mihomo 拉取订阅、启动本地代理并探测可用节点。
# 环境变量:
#   PROXY_SUBSCRIPTION_URL  订阅链接（必填才启用）
#   PROXY_TEST_URL          基础连通性探测目标，默认 https://www.google.com/generate_204
#   PROXY_SITE_TEST_URL     站点兼容性探测目标；设置后逐节点检查是否返回 JSON
#   PROXY_REQUIRED          true 时探测失败则退出 1
#   PROXY_PORT              本地 mixed-port，默认 7890

set -euo pipefail

if [[ -z "${PROXY_SUBSCRIPTION_URL:-}" ]]; then
	echo "[INFO] PROXY_SUBSCRIPTION_URL not set, skip proxy setup"
	exit 0
fi

PROXY_DIR="${RUNNER_TEMP:-/tmp}/checkin-proxy"
PROXY_PORT="${PROXY_PORT:-7890}"
PROXY_TEST_URL="${PROXY_TEST_URL:-https://www.google.com/generate_204}"
PROXY_SITE_TEST_URL="${PROXY_SITE_TEST_URL:-}"
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.0}"
PROXY_REQUIRED="${PROXY_REQUIRED:-false}"

mkdir -p "${PROXY_DIR}"
cd "${PROXY_DIR}"

echo "[INFO] Downloading mihomo ${MIHOMO_VERSION}..."
ARCHIVE="mihomo-linux-amd64-${MIHOMO_VERSION}.gz"
if ! curl --retry 3 --retry-delay 5 --retry-all-errors -fsSL -o "${ARCHIVE}" \
	"https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${ARCHIVE}"; then
	echo "[WARN] Failed to download mihomo ${MIHOMO_VERSION}, skip proxy setup"
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi
gunzip -f "${ARCHIVE}"
chmod +x "mihomo-linux-amd64-${MIHOMO_VERSION}"
MIHOMO_BIN="${PROXY_DIR}/mihomo-linux-amd64-${MIHOMO_VERSION}"

echo "[INFO] Downloading proxy subscription/configuration..."
if ! curl --retry 3 --retry-delay 3 --retry-all-errors -fsSL \
	-o source-subscription.yaml "${PROXY_SUBSCRIPTION_URL}"; then
	echo "[FAILED] Unable to download proxy subscription/configuration"
	exit 1
fi

# 同时兼容纯 provider 订阅与完整 Mihomo 配置。provider 文件只允许顶层 proxies。
if ! uv run python - <<'PY'
import sys
import yaml

with open('source-subscription.yaml', encoding='utf-8') as source:
    data = yaml.safe_load(source)

if not isinstance(data, dict) or not isinstance(data.get('proxies'), list) or not data['proxies']:
    print('[FAILED] Subscription/configuration contains no inline proxies')
    sys.exit(1)

with open('subscription.yaml', 'w', encoding='utf-8') as target:
    yaml.safe_dump({'proxies': data['proxies']}, target, allow_unicode=True, sort_keys=False)

print(f'[INFO] Extracted {len(data["proxies"])} inline proxy node(s)')
PY
then
	exit 1
fi

cat > config.yaml <<EOF
mixed-port: ${PROXY_PORT}
external-controller: 127.0.0.1:9090
allow-lan: false
ipv6: false
mode: rule
log-level: warning
unified-delay: true

proxy-providers:
  subscription:
    type: file
    path: ./subscription.yaml
    health-check:
      enable: true
      interval: 300
      url: https://www.gstatic.com/generate_204

proxy-groups:
  - name: CHECKIN
    type: select
    use:
      - subscription

rules:
  - MATCH,CHECKIN
EOF

echo "[INFO] Starting mihomo on 127.0.0.1:${PROXY_PORT}..."
nohup "${MIHOMO_BIN}" -d "${PROXY_DIR}" -f config.yaml > mihomo.log 2>&1 &
echo $! > mihomo.pid

PROXY_URL="http://127.0.0.1:${PROXY_PORT}"
READY=false
for attempt in $(seq 1 45); do
	if curl -fsS -x "${PROXY_URL}" --max-time 20 "${PROXY_TEST_URL}" -o /dev/null 2>/dev/null; then
		READY=true
		break
	fi
	echo "[INFO] Waiting for proxy health check (${attempt}/45)..."
	sleep 2
done

if [[ "${READY}" != "true" ]]; then
	echo "[FAILED] Proxy health check failed for ${PROXY_TEST_URL}"
	tail -n 30 mihomo.log || true
	if [[ -f mihomo.pid ]]; then
		kill "$(cat mihomo.pid)" 2>/dev/null || true
	fi
	if [[ "${PROXY_REQUIRED}" == "true" ]]; then
		exit 1
	fi
	exit 0
fi

if [[ -n "${PROXY_SITE_TEST_URL}" ]]; then
	echo "[INFO] Selecting a proxy node compatible with the target site..."
	SELECTED=false
	PROXY_NODES=()
	for attempt in $(seq 1 30); do
		mapfile -t PROXY_NODES < <(
			curl -fsS --max-time 10 http://127.0.0.1:9090/providers/proxies/subscription 2>/dev/null |
				python3 -c 'import json,sys; data=json.load(sys.stdin); [print(item["name"]) for item in data.get("proxies", []) if item.get("name")]' 2>/dev/null || true
		)
		if [[ "${#PROXY_NODES[@]}" -gt 0 ]]; then
			break
		fi
		echo "[INFO] Waiting for subscription nodes (${attempt}/30)..."
		sleep 2
	done

	if [[ "${#PROXY_NODES[@]}" -eq 0 ]]; then
		echo "[FAILED] Subscription provider loaded no proxy nodes"
		tail -n 30 mihomo.log || true
		if [[ "${PROXY_REQUIRED}" == "true" ]]; then
			exit 1
		fi
	fi

	echo "[INFO] Loaded ${#PROXY_NODES[@]} proxy node(s); testing target compatibility..."
	for node in "${PROXY_NODES[@]}"; do
		payload=$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1]}))' "${node}")
		if ! curl -fsS --max-time 10 -X PUT \
			-H 'Content-Type: application/json' \
			-d "${payload}" \
			http://127.0.0.1:9090/proxies/CHECKIN >/dev/null; then
			continue
		fi

		if response=$(curl -fsS -x "${PROXY_URL}" --max-time 20 \
			-H 'Accept: application/json' \
			-H 'User-Agent: Mozilla/5.0' \
			"${PROXY_SITE_TEST_URL}" 2>/dev/null) && \
			printf '%s' "${response}" | python3 -c 'import json,sys; data=json.load(sys.stdin); sys.exit(0 if isinstance(data, dict) else 1)' 2>/dev/null; then
			echo "[SUCCESS] Found a target-compatible proxy node"
			SELECTED=true
			break
		fi
		echo "[INFO] Current node is blocked by target verification, trying next node..."
	done

	if [[ "${SELECTED}" != "true" ]]; then
		echo "[FAILED] No proxy node returned valid JSON from target site"
		if [[ "${PROXY_REQUIRED}" == "true" ]]; then
			exit 1
		fi
	fi
fi

echo "[SUCCESS] Proxy is ready: ${PROXY_URL}"
echo "[INFO] Proxy is scoped to CHECKIN_PROXY_URL (browser/python only, not global HTTP_PROXY)"
if [[ -n "${GITHUB_ENV:-}" ]]; then
	echo "CHECKIN_PROXY_URL=${PROXY_URL}" >> "${GITHUB_ENV}"
fi
