# AWS deployment (EC2 + nginx + CodeDeploy), same pattern as nfl-quiz

This mirrors **nfl-quiz**’s flow: **GitHub Actions** (OIDC → AWS) uploads a release **zip** to the **S3 artifact bucket** from CloudFormation stack **`AwsInfra-Ec2Nginx`**, then **AWS CodeDeploy** runs **`appspec.yml`** lifecycle hooks (**`deploy/*.sh`**) on the nginx EC2 instance.

Public URL path for this app: **`/deephaven-experiments/`** (Gunicorn on **`127.0.0.1:8082`**, **one worker** because of the embedded Deephaven JVM). Must match **`AwsInfra-Ec2Nginx`** in aws-infra (`ec2-nginx-stack.ts`).

---

## One-time: GitHub repository

1. Create a new repository on GitHub (e.g. `deephaven-experiments`).
2. From this project directory:

   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin git@github.com:<you>/<repo>.git
   git push -u origin main
   ```

3. In the repo **Settings → Secrets and variables → Actions**:
   - **Secret:** `AWS_ROLE_TO_ASSUME` = ARN of the IAM role used for nfl-quiz (or a role with the same permissions; see below).
4. **Variables** (optional; defaults match nfl-quiz):
   - `AWS_REGION` (e.g. `us-east-1`)
   - `AWS_EC2_STACK_NAME` if your stack is not `AwsInfra-Ec2Nginx`

Workflow file: **`.github/workflows/deploy-aws.yml`** (runs on push to **`main`** and **workflow_dispatch**).

---

## One-time: IAM for GitHub Actions (OIDC)

Use the **same trust + permissions model** as nfl-quiz’s **`deploy/README.md`**. The role needs at least:

| Area | Access |
|------|--------|
| CloudFormation | `DescribeStacks` on `AwsInfra-Ec2Nginx` (or your `AWS_EC2_STACK_NAME`) |
| S3 | `PutObject`, `GetObject`, `ListBucket` on the artifact bucket from output **`Ec2NginxArtifactBucketName`** (objects under app prefixes such as `deephaven-experiments/releases/`) |
| CodeDeploy (GitHub role) | `CreateDeployment`, `RegisterApplicationRevision`, `GetDeployment`, `GetDeploymentConfig`, `GetApplicationRevision` for outputs **`CodeDeployAppName`** / **`CodeDeployDeploymentGroupName`** |

### EC2 instance profile must be allowed to **read** deployment artifacts

CodeDeploy pulls the revision from S3 using the **instance role**. Ensure **aws-infra** grants **`s3:GetObject`** (and **`ListBucket`** if required by your bucket policy) for the artifact bucket keys under **`deephaven-experiments/releases/*`** (and the shared CodeDeploy bucket prefix if applicable).

---

## One-time: EC2 instance sizing & Java

- **Deephaven** needs **JDK 17+** and a fair amount of **RAM**. A **t3.small** often works but **`t3.medium` or larger** is safer for `-Xmx2g`. Adjust **`DEEPHAVEN_HEAP`** in **`/etc/deephaven-experiments.env`** on the instance if needed.
- The install script installs **`java-17-amazon-corretto-headless`** with **`dnf`** / **`yum`** when Java 17 is not already on the PATH.

---

## Nginx (single source of truth: aws-infra)

The combined vhost (**`/nginx-health`**, **`/`** → 8081, **`/nfl-quiz/`**, **`/deephaven-experiments/`**, etc.) lives only in **`aws-experimentation/aws-infra`** (`ec2-nginx-stack.ts` user data). **`remote-install.sh` does not modify nginx.** Change routes by updating CDK and redeploying **`AwsInfra-Ec2Nginx`** (or replacing the instance so user data re-runs).

---

## Manual / local deploy (AWS CLI + CodeDeploy)

From repo root (with AWS credentials), mirror CI:

```bash
export AWS_REGION=us-east-1
STACK="${AWS_EC2_STACK_NAME:-AwsInfra-Ec2Nginx}"
BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2NginxArtifactBucketName'].OutputValue" --output text)
APP=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='CodeDeployAppName'].OutputValue" --output text)
DG=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='CodeDeployDeploymentGroupName'].OutputValue" --output text)

cd frontend && npm ci && VITE_BASE=/deephaven-experiments/ npm run build && cd ..
zip -r /tmp/deephaven-experiments.zip . \
  -x '*/.git/*' -x '.git/*' -x 'frontend/node_modules/*' -x 'backend/.venv/*' -x '*.pyc' -x '*__pycache__/*'
KEY="deephaven-experiments/releases/local-$(git rev-parse HEAD).zip"
aws s3 cp /tmp/deephaven-experiments.zip "s3://${BUCKET}/${KEY}"
DEPLOYMENT_ID=$(aws deploy create-deployment --application-name "$APP" --deployment-group-name "$DG" \
  --s3-location "bucket=${BUCKET},key=${KEY},bundleType=zip" --query deploymentId --output text)
aws deploy wait deployment-successful --deployment-id "$DEPLOYMENT_ID"
```

---

## Service commands (on the instance)

```bash
sudo systemctl stop deephaven-experiments
sudo systemctl start deephaven-experiments
```

Or use **Session Manager** and run the same commands in a shell.

---

## URLs

After deploy: **`http://<Elastic IP>/deephaven-experiments/`** (same host as nfl-quiz; stack outputs **`DeephavenExperimentsUrl`** / **`NginxElasticIp`** / **`NginxHttpsBaseUrl`** depending on your CDK setup).

---

## Troubleshooting

| Symptom | Check |
|--------|--------|
| 502 from nginx | Use the exact path **`/deephaven-experiments/`** (spelling **experiments**, not *experiements*). On the host: `systemctl status deephaven-experiments`, `sudo curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8082/api/health`. Stale **`DEEPHAVEN_HEAP=-Xmx256m`** in **`/etc/deephaven-experiments.env`** causes JVM OOM—redeploy this repo (install resets heap to **`-Xmx4g`**) or edit the file and **`systemctl restart deephaven-experiments`**. Logs: `journalctl -u deephaven-experiments -n 80 --no-pager`. |
| 502 on `/nfl-quiz/` | Ensure **nfl-quiz** is installed and on **8080**: `systemctl status nfl-quiz`. Nginx for `/nfl-quiz/` is CDK-only. |
| `pip` / Deephaven install slow | **AfterInstall** allows **900s**; first deploy can take many minutes. |
| Wrong nginx `projectName` / missing `learn-aws-apps.conf` | Set CDK context **`projectName`** to match; redeploy **`AwsInfra-Ec2Nginx`**. Conf path is **`/etc/nginx/conf.d/<projectName>-apps.conf`**. |
| **`403` / failed revision download on the instance** | **EC2 instance role** must allow **S3 read** on your revision key (**`deephaven-experiments/releases/*.zip`**). Fix IAM in **aws-infra** and redeploy. |
| **`pip` → `incomplete-download` / `not enough bytes` on `deephaven_server-…whl`** | Transient **PyPI** connectivity from the instance (large ~250MB wheel). **`deploy/after_install.sh`** uses long timeouts and extra resume retries; **re-run the deploy**. If it persists, use a larger instance / better egress, a **PyPI mirror**, or bake a **golden AMI** with the venv preinstalled. |
| **`pip` → `[Errno 28] No space left on device`** | **Disk full.** The Deephaven wheel + venv needs **several GiB** free on the **root (EBS) volume**. Grow the root volume (e.g. **≥20–30 GiB** for this app), or free space (`dnf clean all`, `journalctl --vacuum-time=3d`, remove old trees under `/opt`). **`after_install.sh`** sets **`TMPDIR=/var/tmp`** so large downloads do not use small **RAM-backed `/tmp`**. |
