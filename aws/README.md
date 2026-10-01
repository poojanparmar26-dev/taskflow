# TaskFlow — AWS Production Deployment Guide

> **Region:** `ap-south-1` (Asia Pacific - Mumbai)  
> **Target Architecture:** Ubuntu 24.04 LTS on AWS EC2 (`t3.small` / `t3.micro`)  
> **Storage & Persistence:** 30GB gp3 EBS Volume (SQLite database at `database/taskflow.db` & attachments at `uploads/chat/`)  
> **Networking & Routing:** Nginx Reverse Proxy (Frontend SPA + `/api/` + `/socket.io/` WebSocket upgrades)  
> **Application Code Changes:** **ZERO (0)** — Unmodified TaskFlow source code, identical to local & Railway environments.

---

## 📁 Package Contents

| File | Purpose |
| :--- | :--- |
| `aws/taskflow-cloudformation.yaml` | AWS CloudFormation Infrastructure-as-Code template. Provisions EC2, Security Group (80, 443, 22), 30GB gp3 persistent EBS volume, and automated provisioning. |
| `aws/user-data.sh` | Standalone EC2 UserData bootstrap script for launching directly from the EC2 Console or Ubuntu CLI. |
| `aws/nginx-taskflow.conf` | Production Nginx reverse proxy configuration with WebSocket upgrade headers (`Upgrade`, `Connection "Upgrade"`), `client_max_body_size 35M`, and SPA `try_files` fallback. |
| `aws/taskflow.service` | `systemd` unit configuration running `python -m backend.app` under `www-data` with auto-restart on failure. |

---

## 🏗️ Architecture Overview

```
                          Internet (Clients)
                                  │
                                  ▼
                   ┌──────────────────────────────┐
                   │    AWS Security Group        │
                   │  Ports: 80 (HTTP), 443 (TLS) │
                   └──────────────┬───────────────┘
                                  │
                                  ▼
                     EC2 Instance (ap-south-1)
                   ┌──────────────────────────────┐
                   │       Nginx Reverse Proxy     │
                   │       (Listening on :80)     │
                   └──────┬───────────────┬───────┘
                          │               │
            Static Files  │               │ Reverse Proxy (/api, /socket.io)
            (/index.html) │               │ with WebSocket Upgrade
                          ▼               ▼
                   ┌─────────────┐ ┌──────────────────────────────┐
                   │ Vite SPA    │ │ Flask-SocketIO Backend        │
                   │ dist/       │ │ (systemd daemon on :5000)    │
                   └─────────────┘ └──────────────┬───────────────┘
                                                  │
                                                  ▼
                                   ┌──────────────────────────────┐
                                   │  Persistent EBS (gp3)         │
                                   │  • database/taskflow.db      │
                                   │  • uploads/chat/             │
                                   └──────────────────────────────┘
```

---

## 🚀 Deployment Method 1: CloudFormation (Recommended)

### Step 1: Open CloudFormation in AWS Console
1. Navigate to the **AWS Management Console**.
2. Set your active region to **ap-south-1 (Mumbai)** in the top navigation bar.
3. Open **CloudFormation** -> Click **Create stack** -> **With new resources (standard)**.

### Step 2: Upload Template
1. Under **Prerequisite - Prepare template**, select **Template is ready**.
2. Under **Specify template**, select **Upload a template file**.
3. Choose the file `aws/taskflow-cloudformation.yaml` from your local machine.
4. Click **Next**.

### Step 3: Configure Parameters
- **Stack name:** `taskflow-prod`
- **InstanceType:** `t3.small` (Recommended: 2GB RAM. Note: A 2GB swap file is automatically configured for build safety).
- **KeyName:** *(Optional)* Select your existing EC2 Key Pair if you want SSH access.
- **SSHLocation:** `0.0.0.0/0` (or your specific corporate/office IP CIDR).
- **SecretKey:** Enter a secure secret key for Flask session encryption.
- **JwtSecretKey:** Enter a secure secret key for JWT validation.
- **ResendApiKey:** Enter your `re_...` Resend API Key for emails.
- **MailFrom:** `TaskFlow <onboarding@resend.dev>` or your verified domain sender.
- **ClerkSecretKey:** *(Optional)* Your Clerk backend secret key.
- **ClerkPublishableKey:** *(Optional)* Your Clerk backend publishable key.
- **ViteClerkPublishableKey:** *(Optional)* Your Clerk frontend publishable key.
- **GitRepositoryUrl:** *(Optional)* If your code is in a Git repo, enter the URL. Otherwise, leave blank and upload directly.

### Step 4: Review and Launch
1. Click **Next** through Options.
2. Review the summary and click **Submit**.
3. The stack will enter `CREATE_IN_PROGRESS` and complete within 3–5 minutes.
4. Once `CREATE_COMPLETE` is shown, go to the **Outputs** tab to view your **WebsiteURL** (`http://<EC2_PUBLIC_IP>`) and **ApiHealthURL** (`http://<EC2_PUBLIC_IP>/api/health`).

---

## 🚀 Deployment Method 2: AWS CLI

You can also deploy the CloudFormation stack directly via the AWS CLI:

```bash
aws cloudformation create-stack \
  --stack-name taskflow-prod \
  --template-body file://aws/taskflow-cloudformation.yaml \
  --region ap-south-1 \
  --parameters \
      ParameterKey=InstanceType,ParameterValue=t3.small \
      ParameterKey=SecretKey,ParameterValue="your-flask-secret" \
      ParameterKey=JwtSecretKey,ParameterValue="your-jwt-secret" \
      ParameterKey=ResendApiKey,ParameterValue="re_your_api_key" \
      ParameterKey=MailFrom,ParameterValue="TaskFlow <onboarding@resend.dev>"
```

Monitor deployment status:
```bash
aws cloudformation describe-stacks --stack-name taskflow-prod --region ap-south-1 --query "Stacks[0].StackStatus"
```

Retrieve website URL after creation:
```bash
aws cloudformation describe-stacks --stack-name taskflow-prod --region ap-south-1 --query "Stacks[0].Outputs"
```

---

## 🚀 Deployment Method 3: Direct EC2 Launch via Console

If you prefer launching an EC2 instance manually without CloudFormation:

1. In AWS Console, go to **EC2** -> **Launch Instance** in `ap-south-1`.
2. **Name:** `TaskFlow-Production`
3. **AMI:** Ubuntu Server 24.04 LTS (HVM), SSD Volume Type (64-bit x86).
4. **Instance Type:** `t3.small` (2 vCPU, 2 GiB RAM).
5. **Key Pair:** Select or create an SSH key pair.
6. **Network Settings:**
   - Allow SSH traffic from Anywhere (or My IP).
   - Allow HTTP traffic from the internet (port 80).
   - Allow HTTPS traffic from the internet (port 443).
7. **Storage:** Change root volume size from 8GB to **30GB gp3**. Ensure **Delete on termination** is set to **No** (to preserve SQLite database and file uploads if instance is ever stopped/recreated).
8. **Advanced Details -> User data:**
   - Copy and paste the entire contents of `aws/user-data.sh`.
9. Click **Launch Instance**.

---

## 📂 Deploying Application Code to the EC2 Instance

If you did not provide a `GitRepositoryUrl` in the template or UserData, transfer your project files to the EC2 instance:

```bash
# 1. From your local machine, rsync or scp the project to EC2
scp -i your-key.pem -r . ubuntu@<EC2_PUBLIC_IP>:/home/ubuntu/taskflow

# 2. SSH into the instance
ssh -i your-key.pem ubuntu@<EC2_PUBLIC_IP>

# 3. Move files to production directory and set permissions
sudo rsync -av --exclude 'venv' --exclude 'node_modules' /home/ubuntu/taskflow/ /var/www/taskflow/
sudo chown -R www-data:www-data /var/www/taskflow
sudo chmod -R 775 /var/www/taskflow/database
sudo chmod -R 775 /var/www/taskflow/uploads

# 4. Build frontend and restart services
cd /var/www/taskflow/frontend && sudo npm install && sudo npm run build
cd /var/www/taskflow && sudo /var/www/taskflow/venv/bin/pip install -r backend/requirements.txt
sudo systemctl restart taskflow
sudo systemctl restart nginx
```

---

## 🔍 Verification & Health Checks

Once deployed, verify all layers:

1. **System Service Status:**
   ```bash
   sudo systemctl status taskflow
   sudo systemctl status nginx
   ```

2. **Backend API Health Check:**
   ```bash
   curl -I http://localhost/api/health
   # Expected response: HTTP/1.1 200 OK
   ```

3. **Application Logs:**
   ```bash
   # UserData execution log
   cat /var/log/taskflow-init.log

   # Backend application stdout/stderr
   tail -f /var/log/taskflow.log
   tail -f /var/log/taskflow.err.log

   # Nginx access & error logs
   sudo tail -f /var/log/nginx/error.log
   ```

4. **Browser Verification:**
   - Open `http://<EC2_PUBLIC_IP>` in your browser.
   - Test Login / Registration (or Demo account: `demo.pm@taskflow.dev` / `TaskflowDemo@2026`).
   - Open TaskFlow Chat to confirm WebSocket connection (`/socket.io/?EIO=4&transport=websocket`) establishes with status 101 Switching Protocols.
   - Upload a chat attachment to verify it persists in `/var/www/taskflow/uploads/chat/`.

---

## 💾 EBS Persistence & Backup Strategy

Because SQLite stores all relational data in a single file (`database/taskflow.db`) and chat files are stored in `uploads/chat/`, persistence on AWS is straightforward:

1. **EBS gp3 Root Volume:** Configured with `DeleteOnTermination: false` in the CloudFormation template, ensuring your data survives instance stop/start cycles.
2. **Automated Daily Backups via AWS Data Lifecycle Manager (DLM):**
   - In AWS Console, go to **EC2** -> **Lifecycle Manager**.
   - Create an **EBS snapshot policy** targeting instances tagged `Name: TaskFlow-Production-Server`.
   - Set schedule to daily at 00:00 UTC with 14-day retention.
   - Snapshots take point-in-time, crash-consistent backups of your SQLite database and attachments without taking down the server.

---

## 🔒 Optional: Free HTTPS via Let's Encrypt / Certbot

To attach a custom domain and enable free automatic SSL:

```bash
# 1. Point your domain DNS A record to your EC2 Public IP
# 2. SSH into your EC2 instance and run:
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com -d www.yourdomain.com
```
Certbot will automatically update the Nginx configuration, install the SSL certificates, and set up auto-renewal.
