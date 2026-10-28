# Security Policy

## Reporting Security Vulnerabilities

If you discover a security vulnerability in tclembedding, please **DO NOT** open a public GitHub issue.

Instead, please report it responsibly:

1. **GitHub Security Advisory**: Use GitHub's private vulnerability reporting
   - Go to: https://github.com/[repository]/security/advisories
   - Click "Report a vulnerability"
   - Provide detailed information about the vulnerability

2. **Email** (if applicable):
   - Send details to: security@[your-domain] (when established)

Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge receipt within 48 hours and work toward a fix promptly.

---

## Security Best Practices for Users

### Database Security

#### 1. Create a Limited-Privilege User

Never use the root user for the application. Create a dedicated user:

```sql
-- Create user with limited privileges
CREATE USER 'embedding_app'@'localhost'
  IDENTIFIED BY 'strong_password_here';

-- Grant only necessary permissions
GRANT SELECT, INSERT, UPDATE ON rag.*
  TO 'embedding_app'@'localhost';

GRANT EXECUTE ON FUNCTION rag.cosine_similarity
  TO 'embedding_app'@'localhost';

FLUSH PRIVILEGES;
```

#### 2. Secure Passwords

- Use strong, randomly generated passwords (minimum 16 characters)
- Include uppercase, lowercase, numbers, and special characters
- Never reuse passwords
- Rotate passwords regularly (every 90 days)

**Password Generator:**
```bash
# Generate strong password on Linux/macOS
openssl rand -base64 32

# Result example: k7xR9pL2mQ4vZ8wN5fG1jH6cB3tX2yU
```

#### 3. Network Security

For local development:
```
MySQL accessible only on localhost
```

For remote deployments:
```
1. Use VPN or SSH tunnel for database access
2. Configure firewall to restrict port 3306
3. Use SSL/TLS for all remote connections
```

**Example: SSH Tunnel to Remote MySQL**
```bash
ssh -L 3306:db-server:3306 user@bastion-host
# Then connect to localhost:3306 as if it were remote MySQL
```

#### 4. Enable MySQL Access Logging

```sql
-- Enable general query log (MySQL 5.7.2+)
SET GLOBAL general_log = 'ON';
SET GLOBAL log_output = 'TABLE';

-- Monitor for suspicious queries
SELECT * FROM mysql.general_log
WHERE event_time > DATE_SUB(NOW(), INTERVAL 1 HOUR)
  AND command_type != 'Sleep';

-- Disable logging when done
SET GLOBAL general_log = 'OFF';
```

### Environment Configuration

#### 1. Use .env Files (Never Commit!)

Create `.env` file (NOT in git):
```
DB_HOST=localhost
DB_USER=embedding_app
DB_PASSWORD=your_strong_password
DB_NAME=rag
```

Load in your Tcl scripts:
```tcl
# Load environment file
if {[file exists .env]} {
    source .env
}

# Use variables
set db [mysql::connect \
    -host $DB_HOST \
    -user $DB_USER \
    -password $DB_PASSWORD \
    -db $DB_NAME]
```

Ensure `.env` is in `.gitignore`:
```
.env
.env.local
.env.*.local
```

#### 2. Use Environment Variables (Production)

Instead of `.env` files, use system environment variables:

```bash
# Set environment variables
export DB_USER="embedding_app"
export DB_PASSWORD="strong_password"
export DB_HOST="localhost"
export DB_NAME="rag"

# Access in Tcl
set db_user [::env DB_USER]
```

#### 3. Never Hardcode Credentials

❌ **WRONG:**
```tcl
set db [mysql::connect -u root -password "MyPassword123"]
```

✅ **CORRECT:**
```tcl
# Use .env or environment variables
set db [mysql::connect \
    -host $DB_HOST \
    -user $DB_USER \
    -password $DB_PASSWORD \
    -db $DB_NAME]
```

### Application Security

#### 1. Input Validation

Always validate user input:

```tcl
# Validate query length
set query "user_input_here"
if {[string length $query] > 5000} {
    error "Query too long (max 5000 characters)"
}

# Validate result limit
set limit 10
if {![string is integer -strict $limit] || $limit < 1 || $limit > 100} {
    error "Invalid limit (must be 1-100)"
}
```

#### 2. Error Handling

Don't expose sensitive information in errors:

❌ **WRONG:**
```tcl
if {[catch {mysql::query $db $sql} err]} {
    puts "Error: $err at [info file] line [info line]"
    # Exposes file paths and line numbers
}
```

✅ **CORRECT:**
```tcl
if {[catch {mysql::query $db $sql} err]} {
    puts "Error executing search. Please try again."
    # Log detailed error internally
    error_log "Database query failed: $err" $query
}
```

#### 3. Update Dependencies Regularly

Keep software updated:

```bash
# Update ONNX Runtime
# Check: https://github.com/microsoft/onnxruntime/releases

# Update Tcl
# Check: https://www.tcl.tk/software/tcltk/

# Update MySQL/MariaDB
# Follow official update procedures
```

#### 4. Monitor and Log

Implement logging for security events:

```tcl
proc security_log {level message} {
    set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set log_file "logs/security.log"

    if {![file exists logs]} {
        file mkdir logs
    }

    set fp [open $log_file a]
    puts $fp "\[$timestamp\] \[$level\] $message"
    close $fp
}

# Log successful and failed authentications
security_log "INFO" "User query executed: [string range $query 0 50]..."
security_log "WARNING" "Failed database connection attempt from [::env REMOTE_ADDR]"
```

### Data Security

#### 1. Backup Strategy

Regular backups are essential:

```bash
# Daily MySQL backup
mysqldump -u embedding_app -p rag > \
    backup/rag_$(date +%Y%m%d).sql

# Encrypt backup
gpg --encrypt backup/rag_*.sql

# Store in secure location
cp backup/rag_*.sql.gpg /secure/storage/
```

#### 2. Encryption at Rest

Consider encrypting sensitive data:

```sql
-- If using MySQL 5.7.10+, enable table encryption
ALTER TABLE youtube_rag ENCRYPTION='Y';
```

#### 3. Encryption in Transit

Use SSL/TLS for remote connections:

```tcl
# MySQL with SSL (requires TLS support)
set db [mysql::connect \
    -host db.example.com \
    -user embedding_app \
    -password $password \
    -db rag \
    -ssl 1 \
    -ssl_key /path/to/client-key.pem \
    -ssl_cert /path/to/client-cert.pem \
    -ssl_ca /path/to/ca-cert.pem]
```

### Model and Model File Security

#### 1. Secure Model Storage

- Store ONNX model files in read-only location
- Restrict file permissions:

```bash
# Make models readable only to application user
chmod 750 models/
chmod 640 models/*/*.onnx
chmod 640 models/*/*.json

# Verify permissions
ls -la models/
```

#### 2. Model Integrity

Verify model files haven't been tampered with:

```bash
# Generate SHA256 hash of model
sha256sum models/e5-small/model.onnx > models/e5-small/model.onnx.sha256

# Verify before use
sha256sum -c models/e5-small/model.onnx.sha256
```

#### 3. Model Updates

When updating models:
- Test in staging environment first
- Verify model output hasn't changed
- Keep old model as backup
- Document version changes

---

## Security Checklist

Use this checklist before deploying to production:

### Pre-Deployment

- [ ] Create dedicated MySQL user (not root)
- [ ] Set strong password for MySQL user
- [ ] Create `.env` file with credentials (NOT in git)
- [ ] Verify `.env` is in `.gitignore`
- [ ] Enable MySQL access logging
- [ ] Verify file permissions (models, scripts)
- [ ] Review error handling (no credential exposure)
- [ ] Update all dependencies to latest versions
- [ ] Test application thoroughly in staging

### Deployment

- [ ] Use environment variables for credentials
- [ ] Configure firewall to restrict database access
- [ ] Enable SSL/TLS for remote MySQL connections
- [ ] Set up automated backups
- [ ] Configure monitoring and alerting
- [ ] Document all security configurations
- [ ] Brief team on security procedures

### Post-Deployment

- [ ] Monitor access logs regularly
- [ ] Check for failed login attempts
- [ ] Verify backups are working
- [ ] Keep audit trail of model changes
- [ ] Schedule regular security reviews
- [ ] Update dependencies monthly
- [ ] Monitor for CVE announcements

---

## Known Limitations

### Current Version (1.0.0)

No known security vulnerabilities. However, be aware of:

1. **CPU-Only Inference**: GPU acceleration not yet supported
2. **Single-Threaded**: No concurrent query protection
3. **Local Models Only**: Models must be local filesystem
4. **No Rate Limiting**: Implement at application level if needed

---

## Security Advisories

### Advisories and Updates

- GitHub Security Advisories: [Security Advisories](https://github.com/[repo]/security/advisories)
- Dependencies:
  - ONNX Runtime: https://github.com/microsoft/onnxruntime/security
  - Tcl: https://www.tcl.tk/
  - MySQL: https://www.mysql.com/

---

## Additional Resources

- [OWASP Database Security](https://owasp.org/www-community/attacks/SQL_Injection)
- [MySQL Security Guide](https://dev.mysql.com/doc/refman/8.0/en/security.html)
- [Tcl Security](https://www.tcl.tk/about/security.html)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)

---

## Security Review

This project has been reviewed for common security vulnerabilities.
See [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for detailed analysis.

---

**Last Updated:** December 21, 2024
**Status:** ✅ Ready for Production Deployment

For questions about security, please refer to this document or open a private security advisory.
