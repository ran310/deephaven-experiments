# AWS deployment (EC2 + nginx + SSM), same pattern as nfl-quiz

This mirrors **nfl-quiz**’s flow: **GitHub Actions** (OIDC → AWS) uploads a release tarball to the **S3 artifact bucket** from CloudFormation stack **`AwsInfra-Ec2Nginx`**, then **`deploy/remote-install.sh`** runs on the nginx EC2 instance via **Systems Manager (SSM)**.

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
| S3 | `PutObject`, `GetObject`, `ListBucket` on the artifact bucket from output **`Ec2NginxArtifactBucketName`** (objects under `deephaven-experiments/releases/` and `nfl-quiz/releases/`) |
| SSM | `SendCommand`, `GetCommandInvocation`, `ListCommandInvocations`, `DescribeInstanceInformation` on the nginx instance |

Restrict `ssm:SendCommand` with `iam:ResourceTag` / instance tags if you use that pattern in CDK.

### EC2 instance profile must be allowed to **read** the tarball

GitHub Actions and the EC2 host use **different** IAM principals. The workflow can upload to `s3://…/deephaven-experiments/releases/…` while **`aws s3 cp` on the instance returns `403 Forbidden` on `HeadObject`** if the **instance profile** only allows `nfl-quiz/releases/*` (or similar).

In **aws-infra / CDK**, extend the nginx instance role (or bucket policy) so it includes at least:

- `s3:GetObject` on `arn:aws:s3:::<artifact-bucket-name>/deephaven-experiments/*`
- `s3:ListBucket` on `arn:aws:s3:::<artifact-bucket-name>` with a `prefix` condition for `deephaven-experiments/` if your policy uses prefix-scoped `ListBucket`

Redeploy the stack (or attach an inline policy), then re-run **Deploy to AWS**.

---

## One-time: EC2 instance sizing & Java

- **Deephaven** needs **JDK 17+** and a fair amount of **RAM**. A **t3.small** often works but **`t3.medium` or larger** is safer for `-Xmx2g`. Adjust **`DEEPHAVEN_HEAP`** in **`/etc/deephaven-experiments.env`** on the instance if needed.
- The install script installs **`java-17-amazon-corretto-headless`** with **`dnf`** / **`yum`** when Java 17 is not already on the PATH.

---

## Nginx (single source of truth: aws-infra)

The combined vhost (**`/nginx-health`**, **`/`** → 8081, **`/nfl-quiz/`**, **`/deephaven-experiments/`**, etc.) lives only in **`aws-experimentation/aws-infra`** (`ec2-nginx-stack.ts` user data). **`remote-install.sh` does not modify nginx.** Change routes by updating CDK and redeploying **`AwsInfra-Ec2Nginx`** (or replacing the instance so user data re-runs).

---

## Manual / local deploy (AWS CLI + SSM)

Same idea as nfl-quiz (from repo root, with AWS credentials):

```bash
chmod +x deploy/remote-install.sh
export AWS_REGION=us-east-1
STACK="${AWS_EC2_STACK_NAME:-AwsInfra-Ec2Nginx}"
BUCKET=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2NginxArtifactBucketName'].OutputValue" --output text)
IID=$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='NginxInstanceId'].OutputValue" --output text)

cd frontend && npm ci && VITE_BASE=/deephaven-experiments/ npm run build && cd ..
tar -czf /tmp/deephaven-experiments.tgz --exclude='./.git' --exclude='./frontend/node_modules' --exclude='./backend/.venv' .
KEY="deephaven-experiments/releases/local-$(git rev-parse HEAD).tar.gz"
aws s3 cp /tmp/deephaven-experiments.tgz "s3://${BUCKET}/${KEY}"

B64=$(base64 -w0 deploy/remote-install.sh 2>/dev/null || base64 deploy/remote-install.sh | tr -d '\n')
PARAMS=$(jq -n --arg b64 "$B64" --arg b "$BUCKET" --arg k "$KEY" '{commands: ["echo \($b64) | base64 -d | bash -s \($b) \($k)"]}')
aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript --parameters "$PARAMS"
```

Then poll **`get-command-invocation`** for success (or use the GitHub Action logs).

---

## Service commands (SSM)

Replace **`$IID`** with your instance id.

```bash
aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl stop deephaven-experiments"]}'
aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters '{"commands":["systemctl start deephaven-experiments"]}'
```

---

## URLs

After deploy: **`http://<Elastic IP>/deephaven-experiments/`** (same host as nfl-quiz; stack outputs **`DeephavenExperimentsUrl`** / **`NginxElasticIp`** / **`NginxHttpsBaseUrl`** depending on your CDK setup).

---

## Troubleshooting

| Symptom | Check |
|--------|--------|
| 502 from nginx | Use the exact path **`/deephaven-experiments/`** (spelling **experiments**, not *experiements*). On the host: `systemctl status deephaven-experiments`, `sudo curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8082/api/health`. Stale **`DEEPHAVEN_HEAP=-Xmx256m`** in **`/etc/deephaven-experiments.env`** causes JVM OOM—redeploy this repo (install resets heap to **`-Xmx4g`**) or edit the file and **`systemctl restart deephaven-experiments`**. Logs: `journalctl -u deephaven-experiments -n 80 --no-pager`. |
| 502 on `/nfl-quiz/` | Ensure **nfl-quiz** is installed and on **8080**: `systemctl status nfl-quiz`. Nginx for `/nfl-quiz/` is CDK-only. |
| `pip` / Deephaven install slow | First SSM run can exceed a few minutes; increase wait loop in the workflow if needed. |
| Wrong nginx `projectName` / missing `learn-aws-apps.conf` | Set CDK context **`projectName`** to match; redeploy **`AwsInfra-Ec2Nginx`**. Conf path is **`/etc/nginx/conf.d/<projectName>-apps.conf`**. |
| **`aws s3 cp` → `403 Forbidden` / `HeadObject`** | **EC2 instance profile** cannot read `deephaven-experiments/releases/*` in the artifact bucket. Fix IAM on the instance role (see **EC2 instance profile must be allowed to read** above). Confirm with Session Manager: `aws sts get-caller-identity` then `aws s3api head-object --bucket … --key deephaven-experiments/releases/….tar.gz`. |
| **`pip` → `incomplete-download` / `not enough bytes` on `deephaven_server-…whl`** | Transient **PyPI** connectivity from the instance (large ~250MB wheel). `remote-install.sh` uses long timeouts and extra resume retries; **re-run the deploy**. If it persists, use a larger instance / better egress, a **PyPI mirror**, or bake a **golden AMI** with the venv preinstalled. |
| **`pip` → `[Errno 28] No space left on device`** | **Disk full.** The Deephaven wheel + venv needs **several GiB** free on the **root (EBS) volume**. Grow the root volume (e.g. **≥20–30 GiB** for this app), or free space (`dnf clean all`, `journalctl --vacuum-time=3d`, remove old trees under `/opt`). The install script sets **`TMPDIR=/var/tmp`** so large downloads do not use small **RAM-backed `/tmp`**. |
