const mysql = require('mysql2/promise');

const config = {
  host:     process.env.DB_HOST     || 'mysql-service',
  port:     process.env.DB_PORT     || 3306,
  user:     process.env.DB_USER     || 'appuser',
  password: process.env.DB_PASSWORD || 'apppassword',
  database: process.env.DB_NAME     || 'k8sapp',
};

let pool;

// MySQL may take a few seconds to start in the pod
// this retries the connection up to 10 times before giving up
async function connectWithRetry(retries = 10, delay = 5000) {
  for (let i = 1; i <= retries; i++) {
    try {
      console.log(`[DB] Connection attempt ${i}/${retries}...`);
      pool = mysql.createPool(config);

      // test the connection
      const conn = await pool.getConnection();
      await conn.ping();
      conn.release();

      console.log('[DB] Connected to MySQL successfully');
      return pool;
    } catch (err) {
      console.error(`[DB] Attempt ${i} failed: ${err.message}`);
      if (i === retries) {
        console.error('[DB] All retries exhausted. Exiting.');
        process.exit(1);
      }
      await new Promise(res => setTimeout(res, delay));
    }
  }
}

async function initDB() {
  await connectWithRetry();

  // create users table if it doesn't exist
  await pool.execute(`
    CREATE TABLE IF NOT EXISTS users (
      id         INT AUTO_INCREMENT PRIMARY KEY,
      username   VARCHAR(50)  NOT NULL UNIQUE,
      email      VARCHAR(100) NOT NULL UNIQUE,
      password   VARCHAR(255) NOT NULL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  `);

  console.log('[DB] Users table ready');
}

function getPool() {
  return pool;
}

module.exports = { initDB, getPool };
