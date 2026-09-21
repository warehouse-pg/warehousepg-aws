# WarehousePG Demo Notebooks
Jupyter notebooks for running live demos against WarehousePG — including a MADlib fraud detection demo (data generation, model training, evaluation, and live scoring, all run directly from notebook cells).

## ⚠️ Security Notice

**This setup is intended for demos only — not for production or shared environments.**

- Jupyter runs with **no password and no token** (anyone who can reach the port has full access, including code execution on the host).
- All traffic between your browser and Jupyter is **plain HTTP, not HTTPS** — nothing is encrypted in transit.
- Jupyter binds to `0.0.0.0`, meaning it listens on every network interface, not just `localhost`.

The only thing standing between "anyone on the internet" and this notebook is your **AWS security group** restricting which IPs can reach port 8888. Do not run this on a coordinator node that also handles production workloads, and do not leave it running longer than you need it for.

## Demo Environment
The demo environment has been built and tested with WarehousePG in AWS. To get started, first deploy WarehousePG in AWS. 

1. [Get your EDB token](https://www.enterprisedb.com/docs/repos/getting_started/get_your_token/)
2. Log into your AWS account
3. Clone the [warehousepg-aws](https://github.com/warehouse-pg/warehousepg-aws) repo
4. Find the Rocky Linux 9 AMI for your region and subscribe to it. This is a free AMI but you must agree to the EULA first. You can also use an AMI in your own account.
5. Upload the `userdata_classic` directory to an s3 bucket in your account. For convenience, an `upload.sh` script is available in this directory which uploads the files to your bucket. Take note of the bucket name as it is used later.
6. Launch AWS CloudFormation and it is recommended to use `warehousepg_classic_local.yaml` template.
7. [Get your ip address](https://www.whatismyip.com/)
8. A key-pair in AWS. This can be created by going to "EC2" and then "Key Pairs". Use .pem file format.
9. Use the default parameters except for the following:
   - `Stack Name` is the name of the deployment
   - `S3Bucket` is the name of the bucket from step 5
   - `AccessToken` is the EDB token from step 1
   - `AMI` from step 4
   - `KeyPair` is your key-pair from step 8
   - `SSHCIDER` is your ip address from step 7 plus `/32`. For example, if your ip address `10.100.3.4`, use `10.100.3.4/32`
   - `VPC` is a VPC in your AWS account
   - `PrivateSubnet` must be in your VPC and also take note of the Availability Zone of the Subnet
   - `PublicSubnet` must be in your VPC and in the same Availability Zone as the Private Subnet
10. After the Stack moves to "CREATE_COMPLETE" status, go to EC2 in the AWS console. Click on Instances and find the coordinator node. The coordinator will be named "<STACK_NAME>_cdw". Find the Public IP address for this instance.
11. Use your private key from your key-pair (step 8) and ssh to the coordinator node ip address (step 10).

```bash
ssh -i mykey.pem rocky@<coordinator-public-ip>
```

12. Once connected, switch to the gpadmin user.

```bash
sudo su - gpadmin
```

## Notebook Setup

Clone this repo onto the coordinator node, then run:

```bash
chmod 755 start_notebook.sh
./start_notebook.sh
```

Follow the instructions on the output of this script. It will tell you to open a port in your Public SecurityGroup.

**What the script does:**
1. Refuses to run as root (Jupyter should run as your normal database user, not root)
2. Kills any already-running Jupyter Notebook process, so re-running this script always gives you a clean, current instance
3. Installs `python3`, `pip`, `gcc`, and Python dev headers via `dnf`
4. Creates a Python virtual environment at `~/jupyter_env` (skipped if it already exists, so re-running the script won't clobber it)
5. Installs `notebook`, `pandas`, `psycopg2-binary`, and `matplotlib` into that environment
6. Starts Jupyter in the background (`nohup`, no password/token, bound to `0.0.0.0:8888`), logging to `~/jupyter.log`
7. If run on a CloudFormation-deployed WarehousePG instance (detected via `/opt/edb/warehousepg/config.sh`), automatically looks up the coordinator's public IP via the AWS CLI and prints the exact URL to open

The script is **safe to re-run** — it won't duplicate the virtual environment or leave two Jupyter processes fighting over the same port.

## Accessing Jupyter

1. Open the Public SecurityGroup in AWS and add an inbound rule allowing **your IP** on **TCP port 8888** (not `0.0.0.0/0`)
2. Open a browser to `http://<coordinator-public-ip>:8888` (the setup script will print this URL directly if it can determine it)
3. No login required — you'll land straight in the Jupyter file browser
4. Upload one of the Notebooks in this repo for the demo.

## Stopping Jupyter

```bash
pkill -f "jupyter-notebook"
```

Re-running `start_notebook.sh` at any time will also stop any existing instance and start a fresh one.

## Checking logs

```bash
tail -f ~/jupyter.log
```

## Troubleshooting

**`ModuleNotFoundError` for a package used in a notebook (e.g. `matplotlib`)**

In your Notebook, create a new cell and run:
```
!pip install matplotlib
```

**Can't reach the notebook in a browser**

- Confirm the security group allows your current IP on port 8888 (IP allowlists in security groups don't auto-update if your IP changes)
- Confirm Jupyter is actually running: `ps aux | grep jupyter`
- Check `~/jupyter.log` for startup errors

