#!/usr/bin/env python3
"""Own-VM-only CROWN-2 cloud controller; never starts a probe or changes IAM.

Run on ace-core as ubuntu. The existing SDK requires CLI-only sudo because its
parent home directory is not traversable by ubuntu; no permission/IAM is changed.
Source/CALIBRATION must be durable before `create`.
The default ephemeral IPv4 permits SSH/apt; no address is reserved separately.
Transfers and probe execution are separate from this resource controller.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


PROJECT = "aceapex-bench"
ZONE = "europe-west4-b"
MACHINE = "c4-standard-4"
GCLOUD = "/home/aeterna/google-cloud-sdk/bin/gcloud"
CONFIG = "/home/ubuntu/.config/gcloud"
IMAGE_FAMILY = "ubuntu-2204-lts"
IMAGE_PIN = "ubuntu-2204-jammy-v20261124"
TTL_SECONDS = 7200
PRICE = {
    "compute_usd_per_hour": "0.094635",
    "region": "europe-west4",
    "machine": MACHINE,
    "source": "https://cloud.google.com/spot-vms/pricing?hl=en",
    "retrieved_utc": "2026-11-28T17:26:33.998291Z",
    "source_html_sha256": "67e86103d64e52497ab236c240eb8e65aabbea02a9b5af899e8430b66b868b88",
    "kind": "public-list-price estimate, not actual invoice",
    "extras_included": False,
    "extras": ["30 GiB Hyperdisk Balanced", "ephemeral IPv4", "network transfer", "tax"],
    "disk_usd_per_gib_hour": "0.000115068",
    "disk_gib": 30,
    "spot_ipv4_usd_per_hour": "0.0025",
    "compute_disk_ipv4_usd_per_hour": "0.10058704",
    "disk_price_source": "https://cloud.google.com/compute/disks-image-pricing?hl=en",
    "disk_price_retrieved_utc": "2026-11-28T17:37:26.285368Z",
    "disk_price_html_sha256": "62936373eb21ff701f30eedfc46a2d0b2f32d1dcb782040c0d5e321333812284",
    "ipv4_price_source": "https://cloud.google.com/vpc/network-pricing?hl=en",
    "ipv4_price_retrieved_utc": "2026-11-28T17:37:25.291090Z",
    "ipv4_price_html_sha256": "ff69801aa0553c0c776a388ab9d71dfc1aa622173d86c7a6a7dc125d66e69b5d",
    "disk_baseline_included": {"iops": 3000, "throughput_mib_s": 140},
}
VM_FIELDS = ("id,name,status,zone,machineType,creationTimestamp,labels,scheduling,"
             "disks,networkInterfaces,lastStartTimestamp,lastStopTimestamp")
DISK_FIELDS = "id,name,zone,type,sizeGb,users,status,creationTimestamp,sourceImage,provisionedIops,provisionedThroughput"


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def validate_identity(name, token):
    if not re.fullmatch(r"[a-z0-9]{12,40}", token):
        raise ValueError("token must be 12..40 lowercase letters/digits")
    if not re.fullmatch(r"crown2-bwt-[a-z0-9-]{1,52}", name) or len(name) > 63:
        raise ValueError("explicit VM name must start crown2-bwt- and be <=63 chars")
    if name.endswith("-") or token[:8] not in name:
        raise ValueError("VM name must include the first eight unique token characters")


class Controller:
    def __init__(self, name, token, log):
        validate_identity(name, token)
        self.name, self.token = name, token
        self.labels = {"owner": "hw", "task": "crown2-bwt", "crown2-token": token}
        self.log = Path(log)
        self.log.parent.mkdir(parents=True, exist_ok=True)

    def emit(self, event, **fields):
        record = {"utc": utc(), "event": event, "project": PROJECT,
                  "zone": ZONE, "name": self.name, "token": self.token, **fields}
        line = json.dumps(record, sort_keys=True)
        with self.log.open("a", encoding="utf-8") as stream:
            stream.write(line + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        print(line, flush=True)

    def run(self, args, absent=None):
        # The config belongs to this executor, not the SDK directory's owner.
        prefix = (["sudo", "-n", "env", "CLOUDSDK_CONFIG=" + CONFIG,
                   "CLOUDSDK_CORE_DISABLE_PROMPTS=1", "CLOUDSDK_PAGER="]
                  if os.geteuid() != 0 else [])
        argv = [*prefix, GCLOUD, *args, "--project=" + PROJECT, "--quiet"]
        self.emit("command_start", argv=argv)
        env = dict(os.environ, CLOUDSDK_CONFIG=CONFIG,
                   CLOUDSDK_CORE_DISABLE_PROMPTS="1", CLOUDSDK_PAGER="")
        result = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=300)
        # Never put auth errors/raw SDK diagnostics or startup-script contents in logs.
        absent_result = (absent is not None and result.returncode != 0
                         and absent in result.stderr and "was not found" in result.stderr)
        self.emit("command_end", returncode=result.returncode, absent=absent_result,
                  stderr_sha256=hashlib.sha256(result.stderr.encode()).hexdigest(),
                  error_categories=[e for e in ("PERMISSION_DENIED", "QUOTA_EXCEEDED",
                      "ZONE_RESOURCE_POOL_EXHAUSTED", "UNAUTHENTICATED", "SERVICE_DISABLED")
                      if e in result.stderr])
        if absent_result:
            return None
        if result.returncode:
            raise RuntimeError("gcloud failed; see logged command/error category (raw diagnostics withheld)")
        return json.loads(result.stdout) if result.stdout.strip() else None

    def instance(self):
        return self.run(["compute", "instances", "describe", self.name,
                         "--zone=" + ZONE, "--format=json(" + VM_FIELDS + ")"],
                        absent="/instances/" + self.name)

    def disk(self):
        return self.run(["compute", "disks", "describe", self.name,
                         "--zone=" + ZONE, "--format=json(" + DISK_FIELDS + ")"],
                        absent="/disks/" + self.name)

    def owned(self, vm):
        if (vm.get("name") != self.name or vm.get("zone", "").rsplit("/", 1)[-1] != ZONE
                or any(vm.get("labels", {}).get(k) != v for k, v in self.labels.items())):
            raise ValueError("refusing existing VM: name/zone/owner/task/token mismatch")
        return vm

    def boot(self, vm, disk):
        disks = vm.get("disks", [])
        if len(disks) != 1 or not disks[0].get("boot") or not disks[0].get("autoDelete"):
            raise ValueError("refusing VM: expected exactly one auto-deleting boot disk")
        if disks[0].get("source", "").rsplit("/", 1)[-1] != self.name:
            raise ValueError("refusing VM: boot disk does not have this explicit VM name")
        if (disk is None or disk.get("name") != self.name
                or disk.get("zone", "").rsplit("/", 1)[-1] != ZONE):
            raise ValueError("missing/mismatched task boot disk")
        own_url = "/projects/" + PROJECT + "/zones/" + ZONE + "/instances/" + self.name
        if any(not user.endswith(own_url) for user in disk.get("users", [])):
            raise ValueError("refusing disk attached to another VM")
        return disks[0]

    def validate(self, vm, disk, source_sha=None):
        self.owned(vm)
        self.boot(vm, disk)
        schedule = vm.get("scheduling", {})
        duration = schedule.get("maxRunDuration", {})
        seconds = int(duration.get("seconds", 0)) if isinstance(duration, dict) else 0
        if (vm.get("machineType", "").rsplit("/", 1)[-1] != MACHINE
                or schedule.get("provisioningModel") != "SPOT"
                or schedule.get("instanceTerminationAction") != "DELETE"
                or seconds != TTL_SECONDS or int(duration.get("nanos", 0)) != 0
                or schedule.get("automaticRestart") is not False
                or schedule.get("onHostMaintenance") != "TERMINATE"
                or disk.get("type", "").rsplit("/", 1)[-1] != "hyperdisk-balanced"
                or int(disk.get("sizeGb", 0)) != 30
                or disk.get("sourceImage", "").rsplit("/", 1)[-1] != IMAGE_PIN):
            raise ValueError("VM configuration/TTL differs from the registered cloud envelope")
        if source_sha and vm.get("labels", {}).get("source-sha") != source_sha:
            raise ValueError("existing VM source SHA differs")

    def cost(self, creation_utc):
        created = dt.datetime.fromisoformat(creation_utc.replace("Z", "+00:00"))
        elapsed = max(0.0, (dt.datetime.now(dt.timezone.utc) - created).total_seconds())
        return {"elapsed_allocation_hours": elapsed / 3600,
                "compute_usd_estimate": max(60.0, min(elapsed, TTL_SECONDS)) / 3600 * float(PRICE["compute_usd_per_hour"]),
                "compute_disk_ipv4_base_usd_estimate": max(60.0, min(elapsed, TTL_SECONDS)) / 3600 * float(PRICE["compute_disk_ipv4_usd_per_hour"]),
                "price": PRICE, "estimate_note": "wall allocation estimate; excludes extras and is not an invoice"}

    def receipt(self, vm, disk):
        interfaces = vm.get("networkInterfaces", [])
        ips = [a["natIP"] for interface in interfaces for a in interface.get("accessConfigs", [])
               if a.get("natIP")]
        return {"instance_id": vm.get("id"), "status": vm.get("status"),
                "creation_utc": vm.get("creationTimestamp"), "external_ipv4": ips,
                "boot_disk": disk.get("name"), "boot_disk_id": disk.get("id"),
                "boot_disk_provisioned_iops": disk.get("provisionedIops"),
                "boot_disk_provisioned_throughput": disk.get("provisionedThroughput"),
                "boot_image": disk.get("sourceImage"), "image_family": IMAGE_FAMILY,
                **self.cost(vm["creationTimestamp"]),
                "labels": vm.get("labels"), "scheduling": vm.get("scheduling")}

    def last_creation(self):
        if self.log.exists():
            for line in reversed(self.log.read_text(encoding="utf-8").splitlines()):
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if (row.get("name") == self.name and row.get("token") == self.token
                        and row.get("project") == PROJECT and row.get("creation_utc")):
                    return row["creation_utc"]
        return None

    def create(self, startup_script, source_sha, ssh_keys_file=None):
        if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
            raise ValueError("source SHA must be a full lowercase Git commit")
        startup_script = Path(startup_script).resolve(strict=True)
        if not startup_script.is_file():
            raise ValueError("startup script must be a regular file")
        metadata_files = "startup-script=" + str(startup_script)
        if ssh_keys_file is not None:
            ssh_keys_file = Path(ssh_keys_file).resolve(strict=True)
            if not ssh_keys_file.is_file():
                raise ValueError("SSH public metadata file must be regular")
            metadata_files += ",ssh-keys=" + str(ssh_keys_file)
        existing = self.instance()
        if existing is not None:
            disk = self.disk()
            self.validate(existing, disk, source_sha)
            if existing.get("status") != "RUNNING":
                raise ValueError("existing owned VM is not RUNNING; do not recreate implicitly")
            self.emit("existing_owned_vm", **self.receipt(existing, disk))
            return
        if self.disk() is not None:
            raise ValueError("refusing create: same-name disk already exists")
        labels = dict(self.labels, **{"source-sha": source_sha})
        self.emit("create_intent", source_sha=source_sha,
                  startup_script_sha256=hashlib.sha256(startup_script.read_bytes()).hexdigest(),
                  max_hours=2, max_compute_usd_estimate=0.189270, authorized_estimated_total_usd=2,
                  price=PRICE)
        try:
            self.run(["compute", "instances", "create", self.name, "--zone=" + ZONE,
                      "--machine-type=" + MACHINE, "--provisioning-model=SPOT",
                      "--instance-termination-action=DELETE", "--max-run-duration=2h",
                      "--maintenance-policy=TERMINATE", "--no-restart-on-failure",
                      "--image-project=ubuntu-os-cloud", "--image=" + IMAGE_PIN,
                      "--network-interface=network=default,nic-type=GVNIC",
                      "--boot-disk-type=hyperdisk-balanced", "--boot-disk-size=30GB",
                      "--boot-disk-auto-delete", "--labels=" + ",".join(k + "=" + v for k, v in labels.items()),
                  "--metadata=block-project-ssh-keys=TRUE,enable-oslogin=FALSE",
                  "--metadata-from-file=" + metadata_files,
                      "--format=json(" + VM_FIELDS + ")"])
        except Exception as error:
            # A client timeout may follow successful server-side allocation.
            self.emit("create_operation_failed_no_probes", error=str(error))
            try:
                self.delete()
            except Exception as cleanup_error:
                self.emit("cleanup_not_confirmed", error=str(cleanup_error))
            raise
        vm, disk = self.instance(), self.disk()
        try:
            self.validate(vm, disk, source_sha)
            if vm.get("status") != "RUNNING":
                raise ValueError("created VM is not RUNNING")
        except Exception as error:
            self.emit("validation_failed_no_probes", error=str(error))
            if vm is not None:
                self.delete()
            raise
        self.emit("created_validated", **self.receipt(vm, disk))

    def status(self):
        vm, disk = self.instance(), self.disk()
        if vm is None:
            self.emit("status_absent", disk_absent=disk is None)
            if disk is not None:
                raise ValueError("same-name disk remains; no ownership proof for implicit deletion")
            return
        self.validate(vm, disk)
        self.emit("status_owned", **self.receipt(vm, disk))

    def delete(self):
        vm, disk = self.instance(), self.disk()
        creation = vm.get("creationTimestamp") if vm else self.last_creation()
        if vm is not None:
            self.owned(vm)
            self.boot(vm, disk)
            self.emit("delete_intent", **self.receipt(vm, disk))
            self.run(["compute", "instances", "delete", self.name,
                      "--zone=" + ZONE, "--format=json"])
        for attempt in range(12):
            vm, disk = self.instance(), self.disk()
            if vm is None and disk is None:
                self.emit("deleted_verified", vm_absent=True, boot_disk_absent=True,
                          creation_utc=creation, end_utc=utc(),
                          **(self.cost(creation) if creation else {"price": PRICE,
                             "compute_usd_estimate": None, "elapsed_allocation_hours": None}))
                return
            if vm is not None:
                self.owned(vm)
            if attempt != 11:
                time.sleep(2)
        self.emit("delete_incomplete", vm_absent=vm is None, boot_disk_absent=disk is None)
        raise RuntimeError("own VM/disk not both absent; no unrelated disk cleanup attempted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True, help="unique crown2-bwt-* VM name containing token[:8]")
    parser.add_argument("--token", required=True, help="unique lowercase token; reused for status/delete")
    parser.add_argument("--log", required=True, help="durable JSONL cost/operation receipt log")
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create")
    create.add_argument("--startup-script", required=True)
    create.add_argument("--source-sha", required=True)
    create.add_argument("--ssh-keys-file", help="optional per-instance public SSH metadata, never a private key")
    sub.add_parser("status")
    sub.add_parser("delete")
    args = parser.parse_args()
    control = Controller(args.name, args.token, args.log)
    try:
        if args.command == "create":
            control.create(args.startup_script, args.source_sha, args.ssh_keys_file)
        else:
            getattr(control, args.command)()
    except Exception as error:
        control.emit("failed", error_type=type(error).__name__, error=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
