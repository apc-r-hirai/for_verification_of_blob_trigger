import os
import json
import logging
import requests
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

app = func.FunctionApp()

@app.blob_trigger(arg_name="myblob", path="mycontainer/{name}", connection="BLOB_STORAGE_ACCOUNT", source="EventGrid")

def blob_trigger(myblob: func.InputStream):
    content = myblob.read().decode("UTF-8")
    logging.info(f"Python blob trigger function processed blob\nName: {myblob.name}\nContent: {content}")

    webhook_uri = get_webhook_uri()
    send_notification_to_slack(webhook_uri, myblob.name, content)

def get_webhook_uri():
    key_vault_name = os.getenv("KEY_VAULT_NAME")
    key_vault_uri = f"https://{key_vault_name}.vault.azure.net/"
    credentials = DefaultAzureCredential()
    secret_name = os.getenv("WEBHOOK_SECRET_NAME")
    secret_client = SecretClient(vault_url=key_vault_uri, credential=credentials)

    webhook_uri = secret_client.get_secret(secret_name)
    return webhook_uri.value

def send_notification_to_slack(webhook_uri, name, content):
    slack_message = {
        "text": f"データの更新がありました\n Name: {name} \n Content: {content}"
    }

    json_message = json.dumps(slack_message)
    headers = {'Content-Type': 'application/json'}
    response = requests.post(webhook_uri, data=json_message, headers=headers)

    # Slack通知の送信結果をログに出力
    if response.status_code == 200:
        logging.info("Successed to send notification to Slack.")
    else:
        logging.error(f"Failed to send notification to Slack. Response: {response.text}")