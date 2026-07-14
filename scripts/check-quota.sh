#!/usr/bin/env bash
# ===========================================================================
# check-quota.sh
#
# このリファレンスアーキテクチャ (infra/main.bicep) をデプロイする前に、
# 指定した各 Azure リージョンで「クォータ / SKU の空きがありデプロイ可能か」
# を確認するためのスクリプトです。
#
# 確認するリソースとクォータ:
#   1. App Service プラン      : SKU のリージョン提供状況 (Linux ワーカー)。
#                                既定で B1 / P0v3 / 設定中の SKU を確認します。
#   2. PostgreSQL Flexible Srv : 設定中の SKU / ティアのリージョン提供状況。
#   3. ストレージアカウント    : リージョンあたりのアカウント数クォータ (上限 250)。
#   4. ネットワーク            : Public IP / 仮想ネットワーク / Application Gateway
#                                の使用量とクォータ。
#
# 高速化のための実装:
#   - アクセストークンを一度だけ取得し、以降は curl で ARM REST を直接呼び出し
#     (az の Python 起動オーバーヘッドを排除)。
#   - 各リージョンのチェックを並列実行 (--jobs で同時実行数を調整)。
#   - 呼び出しごとにタイムアウトを設定 (--timeout、既定 30 秒)。
#
# 使い方:
#   ./scripts/check-quota.sh                         # 既定のリージョン一覧を確認
#   ./scripts/check-quota.sh -l japaneast,eastus2    # リージョンを指定
#   ./scripts/check-quota.sh -p infra/main.parameters.json
#   ./scripts/check-quota.sh --skus B1,P0V3,P1V3     # 確認する App Service SKU
#   ./scripts/check-quota.sh --jobs 12 --timeout 20  # 同時実行数 / タイムアウト
#
# 前提:
#   - Azure CLI (az) がインストール済みで `az login` 済みであること。
#   - jq / curl がインストール済みであること。
#   - 対象サブスクリプションが選択済みであること (az account set --subscription ...)。
#
# 注意:
#   App Service / PostgreSQL の「SKU 提供状況」は確認できますが、Premium v3 vCPU
#   や PostgreSQL vCore の「割り当て済みクォータ (0 の可能性)」は、提供されていても
#   別途上限に達している場合があります。最終確認は本スクリプト末尾の what-if コマンド
#   (--show-validate) か、Azure Portal の [クォータ] からの引き上げ申請で行ってください。
# ===========================================================================

set -uo pipefail

# --------------------------- 既定値 ----------------------------------------

# 既定で確認するリージョン (東西日本 + 代表的なゾーン冗長対応リージョン)
# 全 Azure パブリックリージョン (2025 年時点の主要リージョン)
# アメリカ (10)
_R_AMERICAS="eastus,eastus2,westus,westus2,westus3,centralus,northcentralus,southcentralus,westcentralus,canadacentral,canadaeast,brazilsouth"
# ヨーロッパ (12)
_R_EUROPE="northeurope,westeurope,uksouth,ukwest,francecentral,francesouth,switzerlandnorth,germanywestcentral,norwayeast,swedencentral,polandcentral,italynorth"
# アジア太平洋 (12)
_R_APAC="japaneast,japanwest,eastasia,southeastasia,australiaeast,australiasoutheast,centralindia,southindia,koreacentral,koreasouth,newzealandnorth,indonesiacentral"
# 中東・アフリカ (5)
_R_MEA="uaenorth,qatarcentral,israelcentral,southafricanorth,mexicocentral"
DEFAULT_LOCATIONS="${_R_AMERICAS},${_R_EUROPE},${_R_APAC},${_R_MEA}"

PARAM_FILE="infra/main.parameters.json"
LOCATIONS=""
# ユーザー要望により B1 と P0v3 を既定で確認対象に含める
APPSVC_SKUS="B1,P0V3"
SHOW_VALIDATE=false
TIMEOUT="${AZ_TIMEOUT:-30}"   # 各 REST 呼び出しのタイムアウト秒数
JOBS=8                        # リージョンの同時実行数

# --------------------------- 引数解析 --------------------------------------

usage() {
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--locations) LOCATIONS="$2"; shift 2 ;;
    -p|--parameters) PARAM_FILE="$2"; shift 2 ;;
    --skus) APPSVC_SKUS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --show-validate) SHOW_VALIDATE=true; shift ;;
    -h|--help) usage 0 ;;
    *) echo "不明な引数: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$LOCATIONS" ]] && LOCATIONS="$DEFAULT_LOCATIONS"

# --------------------------- 色付け ----------------------------------------

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_NG=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_OK=""; C_NG=""; C_WARN=""; C_DIM=""; C_BOLD=""; C_RST=""
fi

S_OK="${C_OK}OK${C_RST}"
S_NG="${C_NG}NG${C_RST}"
S_WARN="${C_WARN}?${C_RST}"

# --------------------------- 前提チェック ----------------------------------

for tool in az jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "${C_NG}エラー: $tool が見つかりません。${C_RST}" >&2; exit 1; }
done

ACCOUNT_JSON="$(az account show -o json 2>/dev/null)" || {
  echo "${C_NG}エラー: Azure にログインしていません。'az login' を実行してください。${C_RST}" >&2
  exit 1
}
SUB_ID="$(jq -r '.id'   <<<"$ACCOUNT_JSON")"
SUB_NAME="$(jq -r '.name' <<<"$ACCOUNT_JSON")"

# ARM 用アクセストークンを一度だけ取得 (以降は curl で使い回す)
# ネットワーク不通時は空のまま処理を続行し、各 API 呼び出しは「？」として表示します。
TOKEN="$(timeout "$TIMEOUT" az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv 2>/dev/null)"
if [[ -z "$TOKEN" ]]; then
  echo "${C_WARN}警告: アクセストークンの取得に失敗しました。${C_RST}"
  echo "${C_DIM}  ストレージ / ネットワークのクォータ確認はスキップされます。App Service SKU 確認は続行します。${C_RST}"
fi

ARM="https://management.azure.com"

# ARM REST を curl で GET するヘルパー (タイムアウト付き)
arm_get() {
  curl -s --max-time "$TIMEOUT" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    "$1"
}

# --------------------------- パラメーター読み込み --------------------------

# main.parameters.json からデプロイ構成を読み取り、必要数量を算出します。
# ファイルが無い / 値が無い場合は main.bicep の既定値にフォールバックします。
pval() {
  local v=""
  if [[ -f "$PARAM_FILE" ]]; then
    v="$(jq -r --arg k "$1" '.parameters[$k].value // empty' "$PARAM_FILE" 2>/dev/null)"
  fi
  [[ -z "$v" || "$v" == "null" ]] && v="$2"
  echo "$v"
}

CFG_APPSVC_SKU="$(pval appServiceSkuName P1v3)"
CFG_APPSVC_CAP="$(pval appServicePlanCapacity 3)"
CFG_DEPLOY_PG="$(pval deployPostgreSql true)"
CFG_DEPLOY_STORAGE="$(pval deployStorage true)"
CFG_DEPLOY_AGW="$(pval deployApplicationGateway true)"
CFG_DEPLOY_DDOS="$(pval deployDdosProtection false)"

# PostgreSQL の SKU / ティアは postgresql モジュールの既定値
PG_SKU="Standard_B1ms"
PG_TIER="Burstable"

# 設定中の App Service SKU を大文字化し、確認対象 SKU リストに追加 (重複除去)
norm_sku() { echo "$1" | tr '[:lower:]' '[:upper:]'; }
CFG_APPSVC_SKU_U="$(norm_sku "$CFG_APPSVC_SKU")"
IFS=',' read -r -a REQ_SKUS <<<"$APPSVC_SKUS"
REQ_SKUS+=("$CFG_APPSVC_SKU_U")
declare -A _seen=()
SKUS=()
for s in "${REQ_SKUS[@]}"; do
  s="$(norm_sku "$s" | xargs)"
  [[ -z "$s" ]] && continue
  if [[ -z "${_seen[$s]:-}" ]]; then _seen[$s]=1; SKUS+=("$s"); fi
done

# 必要数量
NEED_PUBLIC_IP=0; [[ "$CFG_DEPLOY_AGW" == "true" ]] && NEED_PUBLIC_IP=1
NEED_AGW=0;       [[ "$CFG_DEPLOY_AGW" == "true" ]] && NEED_AGW=1
NEED_VNET=1
NEED_STORAGE=0;   [[ "$CFG_DEPLOY_STORAGE" == "true" ]] && NEED_STORAGE=1

# --------------------------- ヘッダー --------------------------------------

echo
echo "${C_BOLD}=== Azure クォータ / デプロイ可否チェック ===${C_RST}"
echo "サブスクリプション : $SUB_NAME ($SUB_ID)"
echo "パラメーター       : $PARAM_FILE"
echo "リージョン         : $LOCATIONS"
echo "同時実行数 / TO    : ${JOBS} / ${TIMEOUT}s"
echo
echo "${C_BOLD}[デプロイ構成]${C_RST}"
printf "  App Service SKU (設定) : %s / インスタンス数 %s\n" "$CFG_APPSVC_SKU" "$CFG_APPSVC_CAP"
printf "  App Service 確認 SKU   : %s\n" "${SKUS[*]}"
printf "  PostgreSQL             : %s (%s) [deploy=%s]\n" "$PG_SKU" "$PG_TIER" "$CFG_DEPLOY_PG"
printf "  ストレージ             : deploy=%s (必要 %s アカウント)\n" "$CFG_DEPLOY_STORAGE" "$NEED_STORAGE"
printf "  Application Gateway    : deploy=%s (Public IP %s / AGW %s)\n" "$CFG_DEPLOY_AGW" "$NEED_PUBLIC_IP" "$NEED_AGW"
printf "  DDoS 保護プラン        : deploy=%s\n" "$CFG_DEPLOY_DDOS"
echo

# 一時作業ディレクトリ (並列ジョブの出力を集約)
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# 表示名 ("Japan East") <-> リージョンコード ("japaneast") 正規化
canon() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' '; }

# --------------------------- App Service SKU 提供リージョン ----------------

# SKU ごとに list-locations を並列取得。az の list-locations は SKU 個別 (P0V3 等)
# の提供可否を返すため、正確性を優先してこちらを使用し、SKU 分を並列実行します。
echo "${C_DIM}App Service SKU 提供リージョンを並列取得中...${C_RST}"
for sku in "${SKUS[@]}"; do
  (
    timeout "$TIMEOUT" az appservice list-locations --sku "$sku" --linux-workers-enabled -o json 2>/dev/null \
      | jq -r '.[].name' 2>/dev/null | while IFS= read -r n; do canon "$n"; done \
      > "$WORKDIR/appsvc_$sku"
  ) &
done
wait

declare -A APPSVC_REGION_SET
for sku in "${SKUS[@]}"; do
  if [[ -s "$WORKDIR/appsvc_$sku" ]]; then
    while IFS= read -r rc; do [[ -n "$rc" ]] && APPSVC_REGION_SET["$sku|$rc"]=1; done < "$WORKDIR/appsvc_$sku"
  else
    echo "  ${S_WARN} SKU '$sku' の提供リージョン取得に失敗、または対象なし。"
  fi
done

# --------------------------- リージョンごとのチェック (並列) ---------------

# 1 リージョン分のチェックを実行し、結果を $WORKDIR/<idx>.out と .status に書き出す。
check_region() {
  local idx="$1" region="$2"
  local rc; rc="$(canon "$region")"
  local overall_ok=true
  local out="$WORKDIR/$idx.out"

  {
    echo "${C_BOLD}────────────────────────────────────────────────────────${C_RST}"
    echo "${C_BOLD}リージョン: $region${C_RST}"
    echo "${C_BOLD}────────────────────────────────────────────────────────${C_RST}"

    # --- 1. App Service SKU (取得済みキャッシュを参照。追加の API 呼び出しなし) ---
    echo "  [App Service SKU]"
    for sku in "${SKUS[@]}"; do
      if [[ -n "${APPSVC_REGION_SET["$sku|$rc"]:-}" ]]; then
        printf "    %-8s : %s (Linux ワーカー提供あり / 必要インスタンス %s)\n" "$sku" "$S_OK" "$CFG_APPSVC_CAP"
      else
        printf "    %-8s : %s (このリージョンでは提供なし)\n" "$sku" "$S_NG"
        [[ "$sku" == "$CFG_APPSVC_SKU_U" ]] && overall_ok=false
      fi
    done

    # --- 2. PostgreSQL Flexible Server (capabilities REST) ---
    if [[ "$CFG_DEPLOY_PG" == "true" ]]; then
      echo "  [PostgreSQL Flexible Server]"
      local pg_json
      pg_json="$(arm_get "$ARM/subscriptions/$SUB_ID/providers/Microsoft.DBforPostgreSQL/locations/$rc/capabilities?api-version=2024-08-01")"
      if [[ -z "$pg_json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$pg_json"; then
        printf "    %-9s : %s (使用量 API 呼び出しに失敗)\n" "$PG_TIER" "$S_WARN"
      elif jq -e '.value | length > 0' >/dev/null 2>&1 <<<"$pg_json"; then
        if grep -q "$PG_SKU" <<<"$pg_json"; then
          printf "    %-9s : %s (%s 提供あり)\n" "$PG_TIER" "$S_OK" "$PG_SKU"
        else
          printf "    %-9s : %s (%s は提供なし。別 SKU を検討)\n" "$PG_TIER" "$S_WARN" "$PG_SKU"
        fi
      else
        printf "    %-9s : %s (このリージョンでは Flexible Server 非対応)\n" "$PG_TIER" "$S_NG"
        overall_ok=false
      fi
    fi

    # --- 3. ストレージアカウント数クォータ (usages REST) ---
    if [[ "$CFG_DEPLOY_STORAGE" == "true" ]]; then
      echo "  [ストレージ]"
      local st_json used limit
      st_json="$(arm_get "$ARM/subscriptions/$SUB_ID/providers/Microsoft.Storage/locations/$rc/usages?api-version=2023-05-01")"
      used="$(jq -r '.value[]? | select(.name.value=="StorageAccounts") | .currentValue' <<<"$st_json" 2>/dev/null)"
      limit="$(jq -r '.value[]? | select(.name.value=="StorageAccounts") | .limit' <<<"$st_json" 2>/dev/null)"
      if [[ -n "$used" && -n "$limit" && "$used" != "null" ]]; then
        if (( used + NEED_STORAGE <= limit )); then
          printf "    %-16s : %s (使用 %s / 上限 %s、必要 %s)\n" "アカウント数" "$S_OK" "$used" "$limit" "$NEED_STORAGE"
        else
          printf "    %-16s : %s (使用 %s / 上限 %s、必要 %s)\n" "アカウント数" "$S_NG" "$used" "$limit" "$NEED_STORAGE"
          overall_ok=false
        fi
      else
        printf "    %-16s : %s (使用量を取得できませんでした)\n" "アカウント数" "$S_WARN"
      fi
    fi

    # --- 4. ネットワーククォータ (usages REST) ---
    echo "  [ネットワーク]"
    local net_json
    net_json="$(arm_get "$ARM/subscriptions/$SUB_ID/providers/Microsoft.Network/locations/$rc/usages?api-version=2023-11-01")"
    if [[ -n "$net_json" ]] && jq -e '.value' >/dev/null 2>&1 <<<"$net_json"; then
      net_usage_check() {
        local key="$1" label="$2" need="$3" used limit
        used="$(jq -r --arg k "$key" '.value[]? | select(.name.value==$k) | .currentValue' <<<"$net_json" 2>/dev/null | head -1)"
        limit="$(jq -r --arg k "$key" '.value[]? | select(.name.value==$k) | .limit' <<<"$net_json" 2>/dev/null | head -1)"
        if [[ -z "$used" || "$used" == "null" ]]; then
          printf "    %-20s : %s (取得不可)\n" "$label" "$S_WARN"; return
        fi
        if (( used + need <= limit )); then
          printf "    %-20s : %s (使用 %s / 上限 %s、必要 %s)\n" "$label" "$S_OK" "$used" "$limit" "$need"
        else
          printf "    %-20s : %s (使用 %s / 上限 %s、必要 %s)\n" "$label" "$S_NG" "$used" "$limit" "$need"
          overall_ok=false
        fi
      }
      net_usage_check "VirtualNetworks"     "仮想ネットワーク"      "$NEED_VNET"
      (( NEED_PUBLIC_IP > 0 )) && net_usage_check "PublicIPAddresses"   "Public IP (Standard)" "$NEED_PUBLIC_IP"
      (( NEED_AGW > 0 ))       && net_usage_check "ApplicationGateways" "Application Gateway"   "$NEED_AGW"
    else
      printf "    %-20s : %s (ネットワーク使用量 API 呼び出しに失敗)\n" "-" "$S_WARN"
    fi

    if $overall_ok; then
      echo "  ${C_OK}${C_BOLD}=> このリージョンはデプロイ可能と判定されました。${C_RST}"
    else
      echo "  ${C_NG}${C_BOLD}=> このリージョンはデプロイ不可の可能性があります (上記 NG を確認)。${C_RST}"
    fi
  } > "$out"

  if $overall_ok; then echo OK > "$WORKDIR/$idx.status"; else echo NG > "$WORKDIR/$idx.status"; fi
}

# リージョン一覧を配列化
IFS=',' read -r -a LOC_ARR <<<"$LOCATIONS"
REGIONS=()
for loc in "${LOC_ARR[@]}"; do
  loc="$(echo "$loc" | xargs)"; [[ -n "$loc" ]] && REGIONS+=("$loc")
done

# リージョンを並列実行 (同時実行数を JOBS に制限)
echo "${C_DIM}${#REGIONS[@]} 個のリージョンを並列チェック中 (同時 ${JOBS})...${C_RST}"
for i in "${!REGIONS[@]}"; do
  check_region "$i" "${REGIONS[$i]}" &
  # 実行中ジョブが JOBS 個に達したら 1 つ終わるのを待つ
  while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n 2>/dev/null || break; done
done
wait

# --------------------------- 結果表示 (投入順) -----------------------------

for i in "${!REGIONS[@]}"; do
  echo
  cat "$WORKDIR/$i.out" 2>/dev/null
done

# --------------------------- サマリ ----------------------------------------

echo
echo "${C_BOLD}=========================== サマリ ===========================${C_RST}"
for i in "${!REGIONS[@]}"; do
  status="$(cat "$WORKDIR/$i.status" 2>/dev/null)"
  if [[ "$status" == "OK" ]]; then
    printf "  %-18s : %s\n" "${REGIONS[$i]}" "$S_OK"
  else
    printf "  %-18s : %s\n" "${REGIONS[$i]}" "$S_NG"
  fi
done
echo

# --------------------------- 補足: 最終確認方法 ----------------------------

echo "${C_DIM}注意: 上記は「SKU の提供状況」と「取得可能なクォータ使用量」に基づく判定です。"
echo "App Service の Premium v3 vCPU や PostgreSQL vCore は、SKU が提供されていても"
echo "サブスクリプションの割り当てクォータが 0 / 不足の場合があります。"
echo "最終確認は Azure Portal の [クォータ] からの申請、または以下の what-if を利用してください。${C_RST}"
echo

if $SHOW_VALIDATE; then
  cat <<'EOF'
# --- 特定リージョンでの what-if による最終検証例 ---
LOCATION=japaneast
RG=rg-webapp-quotacheck
az group create -n "$RG" -l "$LOCATION"
az deployment group what-if \
  -g "$RG" \
  -f infra/main.bicep \
  -p infra/main.parameters.json \
  -p location="$LOCATION"
# 検証後、不要であればリソースグループを削除:
# az group delete -n "$RG" --yes --no-wait
EOF
  echo
fi
