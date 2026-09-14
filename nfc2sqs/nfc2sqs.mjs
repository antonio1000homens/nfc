import { SQSClient, SendMessageCommand } from '@aws-sdk/client-sqs';
import https from 'https';
import { getRequiredSecret } from '/opt/nodejs/ssm-secrets.mjs';

// SLACK_WEBHOOK_URL is a fixed Slack API endpoint used by all Lambdas
const SLACK_WEBHOOK_URL = 'https://slack.com/api/chat.postMessage';
const SQS_QUEUE_URL = process.env.SQS_QUEUE_URL || "";
const SLACK_CHANNEL = process.env.NFC_SLACK_CHANNEL || "";

// Utility function to send HTTP requests
async function sendHttpRequest(url, options, data) {
    return new Promise((resolve, reject) => {
        const req = https.request(url, options, (res) => {
            let responseData = '';
            res.on('data', (chunk) => (responseData += chunk));
            res.on('end', () => resolve(JSON.parse(responseData)));
        });
        req.on('error', reject);
        if (data) req.write(data);
        req.end();
    });
}

// Send a message to Slack
async function sendToSlack(subject) {
    const slackBotToken = (await getRequiredSecret('SLACK_BOT_TOKEN_PARAMETER')).trim();
    const slackMessage = {
        channel: SLACK_CHANNEL,
        text: `NFC scan received for ${subject}. Processing...`
    };
    console.log("Payload sent to Slack:", JSON.stringify(slackMessage, null, 2)); // Log the payload sent to Slack
    const options = {
        method: 'POST',
        headers: {
            Authorization: `Bearer ${slackBotToken}`,
            'Content-Type': 'application/json'
        }
    };
    try {
        const response = await sendHttpRequest(SLACK_WEBHOOK_URL, options, JSON.stringify(slackMessage));
        if (!response.ok) throw new Error(`Slack API error: ${JSON.stringify(response)}`);
        console.log("Message sent to Slack successfully");
    } catch (error) {
        console.error("Slack API request failed:", error.message);
        throw error;
    }
}

// Send a message to SQS
async function sendToSQS(payload) {
    if (!SQS_QUEUE_URL) {
        throw new Error("SQS_QUEUE_URL is not configured");
    }
    const sqsClient = new SQSClient({});
    const command = new SendMessageCommand({
        QueueUrl: SQS_QUEUE_URL,
        MessageBody: JSON.stringify(payload)
    });
    console.log("Payload sent to SQS:", JSON.stringify(payload, null, 2)); // Log the payload sent to SQS
    try {
        await sqsClient.send(command);
        console.log("Payload sent to SQS successfully");
    } catch (error) {
        console.error("Error sending payload to SQS:", error.message);
        throw error;
    }
}

// Lambda handler
export async function lambdaHandler(event) {
    console.log("Lambda function invoked with event:", JSON.stringify(event));
    try {
        const requiredApiKey = (await getRequiredSecret('REQUIRED_API_KEY_PARAMETER')).trim();
        const headers = event.headers || {};
        const requestApiKey = headers['x-api-key'];

        // Return 401 if API key is missing
        if (!requestApiKey) {
            return { statusCode: 401, body: JSON.stringify({ error: "Invalid origin user" }) };
        }

        if (requiredApiKey && requestApiKey !== requiredApiKey) {
            return { statusCode: 403, body: JSON.stringify({ error: 'Forbidden: Invalid API Key' }) };
        }

        const body = JSON.parse(event.body);
        const subject = body.subject;
        if (!subject || typeof subject !== 'string') {
            return { statusCode: 400, body: JSON.stringify({ error: "Invalid or missing 'subject' in body" }) };
        }

        const payload = {
            realm: "nfc",
            subject: JSON.stringify({ deviceId: subject }), // Map subject to JSON string
            action: "nfcScan"
        };

        await sendToSQS(payload);
        await sendToSlack(subject);
        return { statusCode: 200, body: JSON.stringify({ message: "Payload sent to SQS and Slack successfully" }) };
    } catch (error) {
        console.error("Exception occurred:", error.message);
        return { statusCode: 500, body: JSON.stringify({ error: error.message }) };
    }
}
