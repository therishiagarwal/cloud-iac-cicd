# Cloud IaC + CI/CD Demo (Terraform • Jenkins • Docker • AWS)

Spin up a tiny web app on AWS using **Terraform** (EC2, IAM, SG, S3, ECR) and ship updates via a **Jenkins** pipeline that builds a Docker image, pushes to **ECR**, and redeploys to **EC2**.

---

## ✨ What you get

* **Infrastructure as Code**: reproducible AWS infra with Terraform
* **Containerized app**: minimal Python HTTP server in Docker
* **CI/CD**: Jenkins builds, tests, pushes to ECR, and deploys to EC2
* **One-command cleanup**: `terraform destroy`

---

## 🗺️ Architecture

```
Developer → GitHub ──▶ Jenkins
                      │
                      ├── build Docker image
                      ├── push to Amazon ECR
                      └── SSH → EC2: docker pull & restart container

Terraform ──▶ ECR repo, S3 bucket, Security Group, IAM role/profile, EC2 instance
```

---

## 🧰 Tech stack

* **AWS**: EC2, ECR, IAM, S3, (default VPC)
* **Terraform**: `hashicorp/aws` provider
* **Jenkins**: Pipeline (Declarative) running in Docker
* **Docker**: containerized Python 3.11 app

---

## 📁 Repository structure

```
cloud-iac-cicd/
├─ app/
│  ├─ Dockerfile
│  └─ server.py
├─ jenkins/
│  └─ Jenkinsfile
└─ terraform/
   ├─ main.tf
   ├─ variables.tf
   └─ outputs.tf
```

---

## 🚦 Prerequisites

* AWS account and **programmatic access** (IAM user/role)
* Installed locally: **Git**, **Docker**, **Terraform ≥ 1.5**, **AWS CLI v2**
* Optional local Jenkins (recommended): Docker Desktop running
* An **EC2 key pair** (download the `.pem`)

> Region used throughout: `ap-south-1` (feel free to change).

---

## 🔐 IAM quick setup (minimum practical)

Create two IAM users (or roles):

1. **TerraformProvisioner** – used on your machine to run Terraform

   * Needs permissions to create EC2, SG, ECR, S3, IAM role/profile and `iam:PassRole`.

2. **JenkinsCI** – used by Jenkins to push images

   * Needs ECR push: `ecr:GetAuthorizationToken`, `ecr:*Upload*`, `ecr:PutImage`, `ecr:BatchGetImage`, `ecr:Describe*`.

> For learning, you can temporarily attach AWS managed: `AmazonEC2ContainerRegistryPowerUser` to simplify ECR perms.

---

## ⚙️ Configure AWS CLI

```bash
aws configure
# AWS Access Key ID: <YOUR KEY>
# AWS Secret Access Key: <YOUR SECRET>
# Default region name: ap-south-1
# Default output format: json
```

---

## 🚀 Provision infrastructure (Terraform)

```bash
cd terraform
terraform init
terraform apply -auto-approve
```

Note the outputs:

* `ecr_repository_url` → e.g. `<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/tf-jenkins-demo-repo`
* `ec2_public_ip`
* `app_url` → e.g. `http://<EC2_PUBLIC_DNS>:8080`

> On first boot, EC2 may fail to pull the app image if ECR is still empty. The pipeline (or one manual push) resolves this.

---

## 🐳 (Optional) First push manually

If you want the app running before Jenkins:

```bash
ECR_URI="<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/tf-jenkins-demo-repo"
aws ecr get-login-password --region ap-south-1 | docker login -u AWS --password-stdin ${ECR_URI%/*}

docker build -t helloapp:latest ./app
docker tag helloapp:latest $ECR_URI:latest
docker push $ECR_URI:latest
```

SSH to EC2 and start it once:

```bash
EC2_IP=<EC2_PUBLIC_IP>
ssh -i ~/.ssh/<your-key>.pem ubuntu@$EC2_IP <<'EOF'
set -eux
REGION=ap-south-1
ECR_URI="<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/tf-jenkins-demo-repo"
aws ecr get-login-password --region $REGION | sudo docker login -u AWS --password-stdin ${ECR_URI%/*}
sudo docker pull ${ECR_URI}:latest
sudo docker rm -f helloapp || true
sudo docker run -d -p 8080:8080 --restart unless-stopped --name helloapp ${ECR_URI}:latest
EOF
```

Open `http://<EC2_PUBLIC_DNS>:8080`.

---

## 🧪 App (what’s inside `app/`)

**server.py**

```python
from http.server import BaseHTTPRequestHandler, HTTPServer
import socket, os

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"OK\n"); return
        msg = f"Hello from {socket.gethostname()} | ENV={os.getenv('APP_ENV','dev')}\n"
        self.send_response(200); self.end_headers(); self.wfile.write(msg.encode())

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8080"))
    HTTPServer(("", port), Handler).serve_forever()
```

**Dockerfile**

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY server.py .
EXPOSE 8080
ENV APP_ENV=prod
CMD ["python", "server.py"]
```

---

## 🧵 Jenkins (CI/CD)

Run Jenkins locally in Docker (maps UI to 8081):

```bash
docker run -d --name jenkins -p 8081:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins/jenkins:lts-jdk17

# inside the container, install tools once
docker exec -u root jenkins bash -lc "apt-get update && apt-get install -y docker.io openssh-client curl unzip"
docker exec -u root jenkins bash -lc "curl -Ls https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip && unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install"
docker exec -u root jenkins bash -lc "chmod 666 /var/run/docker.sock"
```

Add credentials (Manage Jenkins → Credentials → Global):

* **aws-creds**: AWS key/secret for JenkinsCI
* **ec2-ssh**: SSH Username with private key (user `ubuntu`, paste your `.pem`)

Create a **Pipeline** job:

* Definition: *Pipeline script from SCM*
* Repo URL: your GitHub repo
* Branch: `main`
* Script Path: `jenkins/Jenkinsfile`
* Trigger: enable **Poll SCM** with `H/2 * * * *` (or GitHub webhook)

**Pipeline stages (summary):**

1. **Build Docker**: `docker build -t helloapp:ci ./app`
2. **Unit Test**: run `python -m py_compile server.py` inside the image
3. **Push to ECR**: login, tag, push `latest` (and optionally `SHA`)
4. **Deploy to EC2**: SSH → `sudo docker pull/run` new image

---

## 🔧 Jenkinsfile (key ideas)

* Use environment variables for ECR URI, EC2 IP, region
* Test inside the built image (no host volume mounts)
* On EC2, run docker with `sudo`
* (Optional) Tag images by commit SHA and deploy that exact tag

---

## 🔒 Security & cost notes

* Restrict Security Group ingress to your IP (`22`, `8080`)
* Rotate/secure IAM keys (use Jenkins credentials, never commit secrets)
* Stop the EC2 instance when idle, or destroy everything:

```bash
cd terraform && terraform destroy -auto-approve
```

---

## 🧩 Troubleshooting

**ECR login 400 Bad Request**

* On Windows PowerShell, avoid line continuations in the pipe; use a single line:

  ```powershell
  aws ecr get-login-password --region ap-south-1 | docker login -u AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com
  ```
* Ensure the IAM principal has `ecr:GetAuthorizationToken`.

**SSH key “UNPROTECTED PRIVATE KEY FILE” on Windows**

* Lock ACLs on the `.pem`:

  ```powershell
  $KEY = "$env:USERPROFILE\.ssh\your-key.pem"
  icacls $KEY /reset
  icacls $KEY /inheritance:r
  icacls $KEY /grant:r "$($env:USERNAME):R"
  ```

**EC2 deploy: `permission denied /var/run/docker.sock`**

* Use `sudo` for docker or add user to docker group on EC2:

  ```bash
  sudo usermod -aG docker ubuntu  # then log out/in
  ```

**App not reachable on 8080**

* Check SG inbound rule for port 8080
* On EC2: `sudo docker ps`, `sudo docker logs helloapp`

---

## 🗺️ Roadmap (nice-to-have upgrades)

* VPC with public/private subnets + NAT
* ALB + Auto Scaling Group
* SSM Session Manager (no SSH/22 open)
* Terraform remote backend (S3 + DynamoDB locking)
* Image scan & IaC security checks in pipeline

---



Built as a learning project for cloud infrastructure automation with Terraform + Jenkins.
