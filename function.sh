#!/bin/bash

# 変数の設定
SUBSCRIPTION="<Subcription ID>"
RESOURCE_GROUP="<リソースグループ名>"
LOCATION="<リージョン名>"
FUNCTION_APP="<関数アプリ名>"
FUNCTION_STORAGE_ACCOUNT="<関数用ストレージアカウント名>"
BLOB_STORAGE_ACCOUNT="<Blob用ストレージアカウント名>"
KEY_VAULT_NAME="<Key Vault キーコンテナ名>"
WEBHOOK_SECRET_NAME="<シークレット名>"
WEBHOOK_URI="<Slack Webhook URL>"
EVENT_SUBSCRIPTION_NAME="<イベントサブスクリプション名>"

# 作業するサブスクリプションの指定
az account set --subscription ${SUBSCRIPTION}

# Resource Groupの作成
az group create --name ${RESOURCE_GROUP} --location ${LOCATION}

# Functions用ストレージアカウントの作成
az storage account create \
--name ${FUNCTION_STORAGE_ACCOUNT} \
--resource-group ${RESOURCE_GROUP} \
--location ${LOCATION} \
--sku Standard_LRS

# Blob用ストレージアカウントの作成
az storage account create \
--name ${BLOB_STORAGE_ACCOUNT} \
--resource-group ${RESOURCE_GROUP} \
--location ${LOCATION} \
--sku Standard_LRS

# Blobコンテナの作成
az storage container create \
--name mycontainer \
--account-name ${BLOB_STORAGE_ACCOUNT} \
--auth-mode login

# Webhook用Key Vaultの作成
az keyvault create \
--name ${KEY_VAULT_NAME} \
--resource-group ${RESOURCE_GROUP} \
--location ${LOCATION}

# Key Vault管理者ロールをログインユーザーに付与
USER_ID=$(az ad signed-in-user show --query id --output tsv)

az role assignment create \
--assignee ${USER_ID} \
--role "Key Vault Administrator" \
--scope /subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.KeyVault/vaults/${KEY_VAULT_NAME}

echo "Waiting for the managed role to be fully registered..."
sleep 30

# Key VaultにWebhookのURIを登録
az keyvault secret set \
--vault-name ${KEY_VAULT_NAME} \
--name ${WEBHOOK_SECRET_NAME} \
--value ${WEBHOOK_URI}

# Azure Functions Appの作成
az functionapp create \
--resource-group ${RESOURCE_GROUP} \
--consumption-plan-location ${LOCATION} \
--runtime python \
--runtime-version 3.10 \
--functions-version 4 \
--name ${FUNCTION_APP} \
--storage-account ${FUNCTION_STORAGE_ACCOUNT} \
--os-type Linux

# 環境変数の設定
az functionapp config appsettings set --name ${FUNCTION_APP} --resource-group ${RESOURCE_GROUP} --settings KEY_VAULT_NAME="${KEY_VAULT_NAME}"
az functionapp config appsettings set --name ${FUNCTION_APP} --resource-group ${RESOURCE_GROUP} --settings WEBHOOK_SECRET_NAME="${WEBHOOK_SECRET_NAME}"
az functionapp config appsettings set --name ${FUNCTION_APP} --resource-group ${RESOURCE_GROUP} --settings BLOB_STORAGE_ACCOUNT__blobServiceUri=https://${BLOB_STORAGE_ACCOUNT}.blob.core.windows.net
az functionapp config appsettings set --name ${FUNCTION_APP} --resource-group ${RESOURCE_GROUP} --settings BLOB_STORAGE_ACCOUNT__queueServiceUri=https://${BLOB_STORAGE_ACCOUNT}.queue.core.windows.net

# Managed IDの付与
az functionapp identity assign --name ${FUNCTION_APP} --resource-group ${RESOURCE_GROUP}

echo "Waiting for the managed identity to be fully registered..."
sleep 60

# プリンシパルIDの取得
PRINCIPAL_ID=$(az functionapp identity show --name ${FUNCTION_APP} --resource-group ${RESOURCE_GROUP} --query principalId --output tsv)

# ストレージ BLOB データ所有者ロールを Azure Functions AppのマネージドIDにアサイン
az role assignment create \
--assignee ${PRINCIPAL_ID} \
--role "Storage Blob Data Owner" \
--scope /subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${BLOB_STORAGE_ACCOUNT}

# ストレージ キュー データ共同作成者ロールを Azure Functions AppのマネージドIDにアサイン
az role assignment create \
--assignee ${PRINCIPAL_ID} \
--role "Storage Queue Data Contributor" \
--scope /subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${BLOB_STORAGE_ACCOUNT}

# KeyVault用ロールをAzure Functions AppのマネージドIDにアサイン
az role assignment create \
--assignee ${PRINCIPAL_ID} \
--role "Key Vault Secrets User" \
--scope /subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.KeyVault/vaults/${KEY_VAULT_NAME}

# Functionsにアプリをデプロイ
func azure functionapp publish ${FUNCTION_APP}

# イベントを報告するエンドポイントのURLを作成
BLOB_EXTENSION_KEY=$(az functionapp keys list --name ${FUNCTION_APP} --resource-group ${RESOURCE_GROUP} --query "systemKeys.blobs_extension" --output tsv)

EVENT_GRID_ENDPOINT="https://${FUNCTION_APP}.azurewebsites.net/runtime/webhooks/blobs?functionName=Host.Functions.blob_trigger&code=${BLOB_EXTENSION_KEY}"

# Event Gridを利用したイベントサブスクリプションを作成
az eventgrid event-subscription create \
--name ${EVENT_SUBSCRIPTION_NAME} \
--source-resource-id /subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${BLOB_STORAGE_ACCOUNT} \
--endpoint ${EVENT_GRID_ENDPOINT} \
--event-delivery-schema EventGridSchema \
--included-event-types Microsoft.Storage.BlobCreated