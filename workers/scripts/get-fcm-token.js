/**
 * Script to get FCM OAuth2 access token from Service Account JSON
 * 
 * Usage:
 *   node scripts/get-fcm-token.js path/to/service-account.json
 * 
 * Or set GOOGLE_APPLICATION_CREDENTIALS environment variable
 */

const { google } = require('googleapis');
const fs = require('fs');
const path = require('path');

async function getAccessToken(serviceAccountPath) {
    try {
        // Load service account JSON
        const serviceAccount = JSON.parse(fs.readFileSync(serviceAccountPath, 'utf8'));

        // Create JWT client
        const jwtClient = new google.auth.JWT(
            serviceAccount.client_email,
            null,
            serviceAccount.private_key,
            ['https://www.googleapis.com/auth/firebase.messaging'],
            null
        );

        // Get access token
        const tokens = await jwtClient.authorize();

        console.log('Access Token:');
        console.log(tokens.access_token);
        console.log('\nToken expires in:', tokens.expiry_date - Date.now(), 'ms');
        console.log('\nTo set as Cloudflare Workers secret:');
        console.log(`wrangler secret put FCM_ACCESS_TOKEN`);
        console.log('Then paste the access token when prompted.');

        return tokens.access_token;
    } catch (error) {
        console.error('Error getting access token:', error.message);
        process.exit(1);
    }
}

// Get service account path from command line or environment
const serviceAccountPath = process.argv[2] || process.env.GOOGLE_APPLICATION_CREDENTIALS;

if (!serviceAccountPath) {
    console.error('Usage: node get-fcm-token.js <path-to-service-account.json>');
    console.error('Or set GOOGLE_APPLICATION_CREDENTIALS environment variable');
    process.exit(1);
}

getAccessToken(serviceAccountPath);


