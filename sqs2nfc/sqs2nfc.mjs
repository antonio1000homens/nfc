import { google } from 'googleapis';
import { GoogleAuth } from 'google-auth-library';
import https from 'https';
import { getRequiredSecret } from '/opt/nodejs/ssm-secrets.mjs';

// Constants
const SPREADSHEET_ID = process.env.SPREADSHEET_ID || '';
const SHEET_NAME = 'ID';

const SLACK_CHANNEL = process.env.NFC_SLACK_CHANNEL || "";
let cachedServiceAccount = null;

function parseGoogleServiceAccountJson(secretValue) {
    const parsed = JSON.parse(String(secretValue || '').trim());
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error('Google service account credential must be a JSON object');
    }
    if (parsed.type !== 'service_account') {
        throw new Error('Google service account credential type must be service_account');
    }
    return parsed;
}

async function getGoogleServiceAccountJson() {
    if (cachedServiceAccount) {
        return cachedServiceAccount;
    }

    cachedServiceAccount = parseGoogleServiceAccountJson(
        await getRequiredSecret('GOOGLE_SERVICE_ACCOUNT_PARAMETER')
    );
    return cachedServiceAccount;
}

async function fetchDeviceList() {
    console.log("Fetching device list from Google Sheets...");
    const saJson = await getGoogleServiceAccountJson();
    const auth = new GoogleAuth({
        credentials: saJson,
        scopes: ['https://www.googleapis.com/auth/spreadsheets.readonly']
    });

    const sheets = google.sheets({ version: 'v4', auth });
    const range = `${SHEET_NAME}!A:B`;

    try {
        console.log(`Requesting data from spreadsheet ID: ${SPREADSHEET_ID}, range: ${range}`);
        const response = await sheets.spreadsheets.values.get({
            spreadsheetId: SPREADSHEET_ID,
            range: range
        });

        console.log("Raw response from Google Sheets:", JSON.stringify(response.data, null, 2)); // Log raw JSON response
        const rows = response.data.values || [];
        console.log(`Fetched ${rows.length} rows from Google Sheets`);

        // Validate rows to ensure proper formatting
        rows.forEach((row, index) => {
            if (row.length < 2 || typeof row[0] !== 'string' || typeof row[1] !== 'string') {
                console.warn(`Invalid row at index ${index}:`, row);
            }
        });

        const deviceMap = {};
        rows.forEach(row => {
            if (row.length >= 2) {
                deviceMap[row[0]] = row[1];
            }
        });
        console.log("Device map constructed:", deviceMap);
        return deviceMap;
    } catch (error) {
        console.error("Error fetching data from Google Sheets:", error.message);
        console.error("Full error object:", error); // Log full error object for debugging
        throw new Error(`Google Sheets API request failed: ${error.message}`);
    }
}

async function writeToSheet(sheetName, deviceId, deviceName, additionalData = null) {
    console.log(`Writing to sheet: ${sheetName}, Device ID: ${deviceId}, Device Name: ${deviceName}, Additional Data: ${additionalData}`);
    const saJson = await getGoogleServiceAccountJson();

    const auth = new GoogleAuth({
        credentials: saJson,
        scopes: ['https://www.googleapis.com/auth/spreadsheets']
    });

    const sheets = google.sheets({ version: 'v4', auth });

    const values = additionalData
        ? [[deviceId, deviceName, additionalData]]
        : [[deviceId, deviceName]];

    const resource = {
        values: values
    };

    try {
        console.log(`Appending data to spreadsheet ID: ${SPREADSHEET_ID}, sheet: ${sheetName}`);
        await sheets.spreadsheets.values.append({
            spreadsheetId: SPREADSHEET_ID,
            range: `${sheetName}!A:C`,
            valueInputOption: 'RAW',
            resource: resource
        });
        console.log("Data written to Google Sheets successfully");
    } catch (error) {
        console.error("Error writing data to Google Sheets:", error.message);
        throw new Error(`Google Sheets API write request failed: ${error.message}`);
    }
}

async function sendToSlack(actionText, actionValue, deviceFound, deviceName, actionType) {
    const slackBotToken = (await getRequiredSecret('SLACK_BOT_TOKEN_PARAMETER')).trim();
    const introText = actionText;
    const deviceId = (() => {
        try {
            const parsedValue = JSON.parse(actionValue);
            return parsedValue.deviceId || 'Unknown';
        } catch {
            return 'Unknown';
        }
    })();

    const blocks = [
        {
            type: "header",
            text: {
                type: "plain_text",
                text: `${introText}`,
                emoji: true
            }
        },
        {
            type: "section",
            block_id: deviceFound ? "intro_section" : "new_device_section",
            text: {
                type: "mrkdwn",
                text: deviceFound
                    ? `*Device ID:* \`${deviceId}\`\n*Device Name:* \`${deviceName}\``
                    : `*Device ID:* \`${deviceId}\``
            }
        }
    ];

    if (!deviceFound && actionType === "nfcScan") {
        blocks.push({
            type: "input",
            block_id: "device_name_input_section",
            element: {
                type: "plain_text_input",
                action_id: "device_name",
                min_length: 3,
                placeholder: {
                    type: "plain_text",
                    text: "Enter device name (min 3 chars)"
                }
            },
            label: {
                type: "plain_text",
                text: "Name this device"
            }
        });
        blocks.push({
            type: "actions",
            block_id: "submit_decision_actions",
            elements: [
                {
                    type: "button",
                    action_id: "SubmitDeviceName",
                    text: {
                        type: "plain_text",
                        emoji: true,
                        text: "Submit"
                    },
                    style: "primary",
                    value: JSON.stringify({ deviceId }) // Ensure value is a JSON string
                },
                {
                    type: "button",
                    action_id: "Reject",
                    text: {
                        type: "plain_text",
                        emoji: true,
                        text: "ignore"
                    },
                    style: "danger",
                    value: JSON.stringify({ deviceId }) // Ensure value is a JSON string
                }
            ]
        });
    }

    if (deviceFound && actionType === "nfcScan") {
        blocks.push({
            type: "header",
            text: {
                type: "plain_text",
                text: `Replace Battery for ${deviceName} ?`,
                emoji: true
            }
        });
        blocks.push({
            type: "actions",
            block_id: "submit_decision_actions",
            elements: [
                {
                    type: "button",
                    action_id: "replaceBattery",
                    text: {
                        type: "plain_text",
                        emoji: true,
                        text: "Submit"
                    },
                    style: "primary",
                    value: JSON.stringify({ deviceId, deviceName }) // Ensure value is a JSON string
                },
                {
                    type: "button",
                    action_id: "Reject",
                    text: {
                        type: "plain_text",
                        emoji: true,
                        text: "ignore"
                    },
                    style: "danger",
                    value: JSON.stringify({ deviceId }) // Ensure value is a JSON string
                }
            ]
        });
    }

    const slackMessage = {
        channel: SLACK_CHANNEL,
        text: "NFC Scan",
        blocks: blocks
    };

    const slackUrl = 'https://slack.com/api/chat.postMessage';
    const headers = {
        Authorization: `Bearer ${slackBotToken}`,
        'Content-Type': 'application/json'
    };

    try {
        const data = JSON.stringify(slackMessage);
        const options = {
            method: 'POST',
            headers: headers
        };

        await new Promise((resolve, reject) => {
            const req = https.request(slackUrl, options, (res) => {
                let responseData = '';
                res.on('data', (chunk) => (responseData += chunk));
                res.on('end', () => {
                    const response = JSON.parse(responseData);
                    if (!response.ok) {
                        console.error("Slack API error:", response);
                        reject(new Error(`Slack API error: ${JSON.stringify(response)}`));
                    } else {
                        console.log("Message sent to Slack successfully");
                        resolve();
                    }
                });
            });
            req.on('error', (error) => {
                console.error("Error sending message to Slack:", error.message);
                reject(error);
            });
            req.write(data);
            req.end();
        });
    } catch (error) {
        console.error("Slack API request failed:", error.message);
        throw new Error(`Slack API request failed: ${error.message}`);
    }
}

export async function lambdaHandler(event) {
    console.log("Lambda function invoked with event:", JSON.stringify(event));
    try {
        const records = event.Records || [];
        if (records.length === 0) {
            console.error("No records found in event");
            throw new Error("No records found in event");
        }

        const sqsMessage = records[0]; // Assuming one record per invocation
        console.log("Raw SQS message:", JSON.stringify(sqsMessage)); // Log raw SQS message for debugging

        let messageBody;
        try {
            if (typeof sqsMessage.body === 'string') {
                messageBody = JSON.parse(sqsMessage.body);
            } else {
                messageBody = sqsMessage.body;
            }
        } catch (error) {
            console.error("Failed to parse SQS message body:", sqsMessage.body);
            throw new Error(`Invalid JSON in SQS message body: ${error.message}`);
        }

        console.log("Parsed SQS message body:", JSON.stringify(messageBody)); // Log parsed message body

        let subjectJson;
        if (typeof messageBody.subject === 'string') {
            subjectJson = JSON.parse(messageBody.subject);
        } else {
            subjectJson = messageBody.subject;
        }

        let deviceId;
        if (messageBody.action === "modal") {
            const actionValue = subjectJson.actions?.[0]?.value;
            if (actionValue) {
                deviceId = JSON.parse(actionValue).deviceId;
            }
        } else {
            deviceId = subjectJson.deviceId;
        }

        if (!deviceId) {
            console.error("Missing 'deviceId' in subject field or actions value");
            throw new Error("Missing 'deviceId' in subject field or actions value");
        }

        const action = messageBody.action;

        if (action === "nfcScan") {
            console.log("Fetching device map...");
            const deviceMap = await fetchDeviceList();
            console.log("Device map fetched successfully");

            const deviceName = deviceMap[deviceId];
            const deviceFound = !!deviceName;

            const actionText = deviceFound ? "replace" : "add";
            const actionValue = deviceFound
                ? JSON.stringify({ deviceId, deviceName })
                : JSON.stringify({ deviceId });

            await sendToSlack(actionText, actionValue, deviceFound, deviceName, action);

            return {
                statusCode: 200,
                body: JSON.stringify({ message: "Request processed" })
            };
        } else if (action === "modal") {
            console.log("Processing modal action...");
            const payload = messageBody.subject;

            console.log("Decoded payload body:", JSON.stringify(payload, null, 2));

            const actions = payload.actions || [];
            if (actions.length === 0) {
                console.warn("No actions found in payload");
                return { statusCode: 200, body: "No actions found in payload" };
            }

            const blockId = actions[0].block_id;
            const actionId = actions[0].action_id;
            const actionValue = actions[0].value;
            const responseUrl = payload.response_url;

            if (blockId === 'submit_decision_actions' && actionId === 'SubmitDeviceName') {
                let deviceId, deviceName;

                try {
                    const parsedValue = JSON.parse(actionValue);
                    deviceId = parsedValue.deviceId || 'Unknown';
                } catch {
                    console.warn("Failed to parse action value as JSON:", actionValue);
                    deviceId = 'Unknown';
                }

                deviceName = payload.state?.values?.device_name_input_section?.device_name?.value;

                if (!deviceName || deviceName.length < 3) {
                    console.warn("Device name too short or invalid");
                    return { statusCode: 200, body: "Device name too short or invalid" };
                }

                console.log(`Adding device: ${deviceId} with name: ${deviceName}`);
                await writeToSheet('ID', deviceId, deviceName);
                console.log(`Device ${deviceName} added successfully`);

                await sendToSlack("Device Added", JSON.stringify({ deviceId }), true, deviceName);
            } else if (blockId === 'submit_decision_actions' && actionId === 'Reject') {
                const deviceId = actionValue || 'Unknown device ID';
                console.log(`Submission for device ID ${deviceId} rejected`);
                await sendToSlack("Submission Rejected", deviceId, false, null);
            } else if (blockId === 'submit_decision_actions' && actionId === 'replaceBattery') {
                let deviceId, deviceName;

                try {
                    const parsedValue = JSON.parse(actionValue);
                    deviceId = parsedValue.deviceId;
                    deviceName = parsedValue.deviceName;
                } catch (error) {
                    console.error("Failed to parse action value for replaceBattery:", actionValue);
                    throw new Error("Invalid action value format for replaceBattery");
                }

                const currentDate = new Date().toISOString().split('T')[0];

                await writeToSheet('battery', deviceId, deviceName, currentDate);
                console.log(`Battery replaced for device: ${deviceName}`);

                console.log("Sending to Slack with parameters:", {
                    actionText: "Battery Replaced",
                    actionValue: JSON.stringify({ deviceId, deviceName }),
                    deviceFound: true,
                    deviceName: deviceName
                });
                await sendToSlack("Battery Replaced", JSON.stringify({ deviceId, deviceName }), true, deviceName);
            } else if (blockId === 'submit_decision_actions' && actionId === 'Reject') {
                const { name: deviceName } = JSON.parse(actionValue);
                console.log(`Battery replacement ignored for device: ${deviceName}`);
                await sendToSlack("Battery Replacement Ignored", null, false, deviceName);
            } else {
                console.warn("Unhandled action:", actionId);
                return { statusCode: 200, body: "Unhandled action" };
            }

            console.log("Modal action processed successfully");
            return {
                statusCode: 200,
                body: JSON.stringify({ message: "Modal action processed successfully" })
            };
        } else {
            console.warn("Unhandled action type:", action);
            return { statusCode: 200, body: "Unhandled action type" };
        }
    } catch (error) {
        console.error("Exception occurred:", error.message);
        return {
            statusCode: 500,
            body: JSON.stringify({ error: error.message })
        };
    }
}
