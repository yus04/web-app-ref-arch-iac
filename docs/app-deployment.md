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

検証用途向けの簡易手順です。デプロイ後は必ずパブリックアクセスを無効に戻してください。

```bash
APP_NAME=<APP_SERVICE_NAME>          # デプロイ出力の appServiceName
RG=<RESOURCE_GROUP>

# 1) パブリックアクセスを一時的に有効化
az webapp update --name "$APP_NAME" --resource-group "$RG" \
  --set publicNetworkAccess=Enabled

# 2) コードを ZIP デプロイ (Oryx ビルドは IaC の SCM_DO_BUILD_DURING_DEPLOYMENT で有効化済み)
az webapp deploy --name "$APP_NAME" --resource-group "$RG" \
  --type zip --src-path <(cd msdocs-python-flask-webapp-quickstart && zip -r - . ) \
  || echo "zip コマンドが使えない場合は下記の zip 作成手順を参照してください"

# 3) デプロイ後、パブリックアクセスを無効化
az webapp update --name "$APP_NAME" --resource-group "$RG" \
  --set publicNetworkAccess=Disabled
```

ZIP を明示的に作成する場合:

```bash
cd msdocs-python-flask-webapp-quickstart
zip -r ../app.zip . -x '.git/*'
cd ..
az webapp deploy --name "$APP_NAME" --resource-group "$RG" \
  --type zip --src-path app.zip
```

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

```bash
STORAGE=<STORAGE_ACCOUNT_NAME>       # デプロイ出力の storageAccountName
az storage blob upload \
  --account-name "$STORAGE" \
  --container-name pdf \
  --name sample.pdf \
  --file ./sample.pdf \
  --auth-mode login
```

> Storage はパブリックアクセスが無効です。アップロードはプライベートエンドポイント経由 (VNet 内) で行うか、一時的にご自身の IP を許可してください。コンテナー内に PDF 以外のファイルが含まれるとアプリ側でエラー表示になります。

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
