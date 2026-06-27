const http = require('http');

// This port must match the 'Server Port' you typed into the MB20-VL keypad
const PORT = 8000;

const server = http.createServer((req, res) => {
    const url = req.url;

    // Log tracking info to console so you can see when the machine connects
    console.log(`\n[${new Date().toLocaleTimeString()}] 📡 Activity: ${req.method} request to ${url}`);

    // ==========================================
    // 1. DEVICE HANDSHAKE / HEARTBEAT (GET)
    // ==========================================
    // The device hits this to see if your server is alive and ready
    if (req.method === 'GET' && url.includes('/iclock/cdata')) {
        console.log("   ✅ Handshake successful: MB20-VL is connected and online!");

        // ZKTeco firmware strictly requires an 'OK' text response to stay connected
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        res.end('OK');
        return;
    }

    // ==========================================
    // 2. LIVE DATA TRANSMISSION PUSH (POST)
    // ==========================================
    // The device automatically posts raw text here immediately upon fingerprint/face scan
    if (req.method === 'POST' && url.includes('/iclock/cdata')) {
        let rawPayload = '';

        req.on('data', chunk => {
            rawPayload += chunk.toString();
        });

        req.on('end', () => {
            console.log('   📥 Parsing incoming log payload...');

            // Split the raw text string into individual log row lines
            const rows = rawPayload.trim().split('\n');
            const cleanRecords = [];

            rows.forEach(row => {
                // ZK ADMS text strings use tab-separated columns:
                // UserID \t Timestamp \t Status \t PunchType etc.
                const columns = row.split('\t');

                if (columns.length >= 2) {
                    cleanRecords.push({
                        userId: columns[0].trim(),
                        timestamp: columns[1].trim(),
                        status: columns[2] ? columns[2].trim() : '0'
                    });
                }
            });

            // Display your parsed records beautifully in the terminal matrix layout
            console.log('\n=================== 🚀 LIVE RECORD MATRIX ===================');
            if (cleanRecords.length === 0) {
                console.log('   ⚠️ Alert: Received ping but packet layout was blank.');
            } else {
                console.table(cleanRecords);
            }
            console.log('=============================================================');

            // CRUCIAL: Send 'OK' response. 
            // If you don't, the machine will think the download failed and re-send it constantly.
            res.writeHead(200, { 'Content-Type': 'text/plain' });
            res.end('OK');
        });
        return;
    }

    // Fallback response for initialization queries or unhandled device endpoints
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('OK');
});

// Bind to 0.0.0.0 to listen across all network cards targeting port 8000
server.listen(PORT, '0.0.0.0', () => {
    console.log(`\n============================================================`);
    console.log(` 🚀 Seamless ADMS Sync Server is live at http://192.168.0.205:${PORT}`);
    console.log(`    Status: Standing by for real-time biometric push data...`);
    console.log(`============================================================`);
});