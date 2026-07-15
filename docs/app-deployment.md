# アプリケーションのデプロイ手順

このドキュメントは、[web-app-ref-arch-iac](../README.md) でデプロイしたインフラ上に、実際の Web アプリケーションをデプロイする手順をまとめたものです。本 IaC プロジェクトとの疎結合を保つため、アプリケーション固有の手順はこのファイルに分離しています。

対象サンプルアプリケーション:
[yus04/msdocs-python-flask-webapp-quickstart](https://github.com/yus04/msdocs-python-flask-webapp-quickstart) (Python / Flask)

---

## 前提

- [README.md](../README.md) の手順に従って、インフラ (App Service など) のデプロイが完了していること。
- 以下は **IaC 側で自動設定済み**のため、アプリ側での手動設定は不要です。
  - App Service のシステム割り当てマネージド ID の有効化
  - マネージド ID への各種ロール付与 (Storage Blob Data Reader / Monitoring Metrics Publisher / Key Vault Secrets User)
  - マネージド ID の PostgreSQL Entra 管理者登録
  - アプリ設定 (`APPLICATIONINSIGHTS_CONNECTION_STRING` / `POSTGRES_HOST` / `POSTGRES_DB` / `POSTGRES_USER` / `POSTGRES_PORT` / `POSTGRES_SSLMODE` / `AZURE_STORAGE_ACCOUNT_NAME` / `AZURE_STORAGE_CONTAINER_NAME`)

> つまり、アプリケーション側で行うのは「コードのデプロイ」と「動作確認」、および (必要に応じて) 「PDF ファイルのアップロード」のみです。

---

## 1. アプリケーションコードの取得

```bash
git clone https://github.com/yus04/msdocs-python-flask-webapp-quickstart.git
cd msdocs-python-flask-webapp-quickstart
```

---

## 2. App Service へのデプロイ

App Service は**パブリックネットワークアクセスが無効**に構成されており、受信はプライベートエンドポイント経由に限定されています。そのため、インターネット経由の SCM (Kudu) への直接デプロイはできません。以下のいずれかの方法でデプロイします。

### 方法 A: パブリックアクセスを一時的に有効化してデプロイ (簡易)

検証用途向けの簡易手順です。デプロイ後は必ず元の状態に戻してください。

> **重要 (504 GatewayTimeout の回避)**: 本アーキテクチャは App Service の全送信トラフィックを VNet 経由 (`vnetRouteAllEnabled=true`) にしていますが、統合サブネットに送信インターネット経路 (NAT Gateway 等) を配置していません。この状態のままだと、デプロイ時の Oryx ビルド (`pip install` による PyPI アクセス) が外部に到達できず、`504 GatewayTimeout` になります。これを回避するため、**デプロイ中だけ `WEBSITE_VNET_ROUTE_ALL=0` を設定して送信を既定の公開経路に戻し**、完了後に `1` へ戻します。プライベートエンドポイント宛の通信 (10.x / RFC1918) は `WEBSITE_VNET_ROUTE_ALL=0` でも引き続き VNet 経由で到達できるため、DB / Storage / Key Vault へのアクセスには影響しません。

```bash
APP_NAME=<APP_SERVICE_NAME>          # デプロイ出力の appServiceName
RG=<RESOURCE_GROUP>

# 1) パブリックアクセスを一時的に有効化
az webapp update --name "$APP_NAME" --resource-group "$RG" \
  --set publicNetworkAccess=Enabled

# 2) ビルド時の送信を一時的に公開経路へ戻す (504 GatewayTimeout の回避)
az webapp config appsettings set --name "$APP_NAME" --resource-group "$RG" \
  --settings WEBSITE_VNET_ROUTE_ALL=0

# 3) ZIP の作成
zip -r ./app.zip . -x '.git/*'

# 4) コードを ZIP デプロイ (Oryx ビルドは IaC の SCM_DO_BUILD_DURING_DEPLOYMENT で有効化済み)
az webapp deploy --name "$APP_NAME" --resource-group "$RG" \
  --type zip --src-path app.zip --track-status false

# 5) 送信をアーキテクチャ既定 (全送信 VNet 経由) へ戻す
az webapp config appsettings set --name "$APP_NAME" --resource-group "$RG" \
  --settings WEBSITE_VNET_ROUTE_ALL=1

# 6) パブリックアクセスを無効化
az webapp update --name "$APP_NAME" --resource-group "$RG" \
  --set publicNetworkAccess=Disabled
```

> `WEBSITE_VNET_ROUTE_ALL` を変更するとアプリが再起動します。手順 4 の後、必要に応じて `az webapp restart` で再起動を確認してください。
> 恒久的にビルド時の送信経路を確保したい場合は、統合サブネットに NAT Gateway を追加する方法もあります (本 IaC の既定では含めていません)。

### 方法 B: VNet 内の踏み台 / セルフホストエージェントからデプロイ (推奨)

パブリックアクセスを無効に保ったまま運用したい場合は、同一 VNet (またはピアリング済み VNet) に接続された環境からデプロイします。

- VNet 内の VM (踏み台) や、VNet 統合されたセルフホストエージェントから、`az webapp deploy` を実行します。
- App Service のプライベートエンドポイント (`privatelink.azurewebsites.net`) 経由で SCM に到達できます。

---

## 3. 動作確認

### Application Gateway をデプロイした場合

- ブラウザーで `http://<applicationGatewayPublicIp>` (出力値) にアクセスし、アプリのトップページが表示されることを確認します。
- HTTPS / カスタムドメインを設定した場合は、そのドメインでアクセスします (設定手順は [README.md](../README.md#application-gateway-をデプロイした場合-カスタムドメイン--https-の設定) を参照)。

### Application Gateway をデプロイしていない場合

- App Service はパブリックアクセス無効のため、インターネットから直接アクセスできません。
- VNet 内のクライアント (踏み台 VM など) から `https://<appServiceDefaultHostName>` にアクセスして確認します。

---

## 4. 機能別の追加確認

### PostgreSQL (挨拶履歴の保存・削除)

- `/hello` 画面で名前を送信すると、`greetings` テーブルに履歴が保存されます。
- テーブルはアプリ起動時に自動作成されます。マネージド ID による Entra 認証 (パスワードレス) で接続します (IaC で管理者登録済み)。

### Blob Storage (PDF 表示)

- PDF を表示するには、`pdf` コンテナー (既定) に PDF ファイルをアップロードします。
- Storage はデプロイ時に**パブリックネットワークアクセス無効** + **共有キーアクセス無効**でデプロイされるため、ローカルからアップロードするにはこれらを一時的に解除する必要があります。

```bash
STORAGE=<STORAGE_ACCOUNT_NAME>       # デプロイ出力の storageAccountName

# 1. 一時的にパブリックネットワークアクセスと共有キーアクセスを許可
az storage account update \
  --name "$STORAGE" \
  --public-network-access Enabled \
  --default-action Allow \
  --allow-shared-key-access true

# 2. PDF をアップロード (アカウントキー認証)
az storage blob upload \
  --account-name "$STORAGE" \
  --container-name pdf \
  --name sample.pdf \
  --file ./sample.pdf \
  --auth-mode key

# 3. セキュリティ設定を元に戻す (必ず実行してください)
az storage account update \
  --name "$STORAGE" \
  --public-network-access Disabled \
  --default-action Deny \
  --allow-shared-key-access false
```

> **セキュリティ上の注意**: 手順 3 を忘れると Storage がインターネットからアクセス可能かつキー認証が有効な状態のまま残ります。アップロード完了後は速やかに元に戻してください。
>
> **補足**: `--auth-mode login` (Entra ID 認証) を使う場合は、自分のユーザーに **Storage Blob Data Contributor** 以上のロールが必要です。キー認証 (`--auth-mode key`) ならロール割り当て不要で手軽にアップロードできます。
>
> コンテナー内に PDF 以外のファイルが含まれるとアプリ側でエラー表示になります。

### Application Insights (テレメトリ)

- アプリにアクセスした後、Azure Portal の Application Insights → トランザクション検索 / ライブメトリックでテレメトリを確認できます。
- マネージド ID 認証でテレメトリが送信されます (接続文字列は IaC で設定済み)。

---

## 補足

- アプリ設定を変更した場合は、App Service を再起動してください。

```bash
az webapp restart --name "$APP_NAME" --resource-group "$RG"
```

- ローカル開発時は、`APPLICATIONINSIGHTS_CONNECTION_STRING` や `POSTGRES_HOST` などの環境変数が未設定でもアプリは起動します (該当機能はスキップ / エラー表示になります)。詳細はアプリケーションリポジトリの README を参照してください。
