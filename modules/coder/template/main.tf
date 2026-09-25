terraform {
  required_version = ">= 1.3"
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Coder data sources
# ---------------------------------------------------------------------------

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ---------------------------------------------------------------------------
# Workspace parameters (shown to the user when creating a workspace)
# ---------------------------------------------------------------------------

data "coder_parameter" "hypervisor" {
  name         = "hypervisor"
  display_name = "Hypervisor"
  description  = "Which hypervisor backend to use. cloud-hypervisor is fastest; qemu is most compatible."
  default      = "cloud-hypervisor"
  mutable      = false
  icon         = "https://raw.githubusercontent.com/coder/coder/main/site/static/icon/computer.svg"

  option {
    name  = "cloud-hypervisor (recommended)"
    value = "cloud-hypervisor"
  }
  option {
    name  = "QEMU / KVM"
    value = "qemu"
  }
  option {
    name  = "Firecracker"
    value = "firecracker"
  }
}

data "coder_parameter" "memory_mb" {
  name         = "memory_mb"
  display_name = "Memory (MiB)"
  description  = "RAM allocated to the VM. Minimum 1024 MiB."
  default      = "2048"
  type         = "number"
  mutable      = false

  validation {
    min       = 1024
    max       = 65536
    monotonic = "increasing"
  }
}

data "coder_parameter" "vcpus" {
  name         = "vcpus"
  display_name = "vCPUs"
  description  = "Number of virtual CPUs."
  default      = "2"
  type         = "number"
  mutable      = false

  validation {
    min = 1
    max = 32
  }
}

data "coder_parameter" "disk_gb" {
  name         = "disk_gb"
  display_name = "System disk (GiB)"
  description  = "Size of the VM's /var volume (system state: logs, caches, container images). Your home directory is NOT on this volume — it is a host directory shared in over virtiofs and is not size-limited here."
  default      = "20"
  type         = "number"
  mutable      = false

  validation {
    min = 5
    max = 500
  }
}

data "coder_parameter" "store_gb" {
  name         = "store_gb"
  display_name = "Nix build store (GiB)"
  description  = "Size of the writable /nix/store overlay, where anything you build or `nix develop` inside the workspace is written. Backed by a disk image, so it neither consumes the VM's RAM nor is lost on reboot."
  default      = "10"
  type         = "number"
  mutable      = false

  validation {
    min = 2
    max = 200
  }
}

data "coder_parameter" "extra_packages" {
  name         = "extra_packages"
  display_name = "Extra nixpkgs packages"
  description  = "Space-separated list of nixpkgs attribute names to install in the workspace (e.g. 'go rustup nodejs_22')."
  default      = ""
  mutable      = true
}

data "coder_parameter" "microvm_host" {
  name         = "microvm_host"
  display_name = "Microvm host"
  description  = "Which NixOS host runs this workspace's microvm. `offsite-backup` is the dedicated, normally-powered-off host (Coder powers it on/off per workspace — slowest first start); `elserver` is the Coder server host itself (always on, workspace reaches the server directly on the LAN, but shares RAM/CPU with other homelab services)."
  default      = "offsite-backup"
  mutable      = false
  icon         = "https://raw.githubusercontent.com/coder/coder/main/site/static/icon/computer.svg"

  option {
    name  = "offsite-backup (default)"
    value = "offsite-backup"
  }
  option {
    name  = "elserver"
    value = "elserver"
  }
}



# ---------------------------------------------------------------------------
# Admin / deployment variables (set in the template, not per-workspace)
# ---------------------------------------------------------------------------

variable "host_ssh_address" {
  description = "SSH address of the NixOS host running microvm.nix (host:port or just host)."
  default     = "localhost"
}

variable "host_ssh_user" {
  description = "SSH user on the NixOS host. Must be able to run systemctl and write to /var/lib/microvms."
  default     = "root"
}

variable "host_ssh_private_key_path" {
  description = "Absolute path on the Coder provisioner to the SSH private key for the host."
  default     = "/root/.ssh/id_ed25519"
  # NOTE: deliberately NOT marked sensitive. This is only a filesystem path;
  # the key *contents* are read ephemerally by file() during the SSH handshake.
  # Marking it sensitive would taint the null_resource triggers map and the
  # shared connection, and Terraform suppresses ALL remote-exec stdout/stderr
  # whenever a provisioner's config or connection contains a sensitive value —
  # making VM build failures impossible to debug.
}

variable "bridge_name" {
  description = "Name of the bridge interface on the host (see host-setup/README)."
  default     = "microbr0"
}

variable "bridge_subnet" {
  description = "First three octets of the bridge subnet (host is .1, VMs get .10-.250)."
  default     = "192.168.100"
}

variable "nix_cache_url" {
  description = "Optional extra Nix binary cache URL (e.g. https://mycache.cachix.org)."
  default     = ""
}

variable "nix_cache_key" {
  description = "Optional extra Nix binary cache public key."
  default     = ""
}

variable "build_keepalive_minutes" {
  description = <<-EOT
    Minutes after a workspace launch during which the host autostop timer will
    not power off the microvm host. The first workspace build runs `nix build`
    with no VM active yet, so without this guard the autostop timer could shut
    the host down mid-build. Set generously enough to cover a cold first build.
  EOT
  type        = number
  default     = 30
}

variable "coder_server_ip" {
  description = <<-EOT
    Internal IP of the Coder server (elserver). Injected into each workspace
    VM's /etc/hosts alongside coder_server_hostname so the Coder agent can phone
    home without relying on public DNS for the coder hostname.
  EOT
  type        = string
}

variable "coder_server_hostname" {
  description = <<-EOT
    Hostname of the Coder server (e.g. coder.example.com) that workspace VMs
    resolve to coder_server_ip via /etc/hosts. Must match the host part of the
    Coder access URL the agent uses to phone home.
  EOT
  type        = string
}

variable "authorized_ssh_keys" {
  description = <<-EOT
    Newline-separated SSH public keys authorised to log into the workspace VM
    as the workspace user (the VM's `openssh.authorizedKeys.keys`). The
    `coder-push-microvm-template` wrapper on the Coder server injects this
    from the Nix option `coder.server.authorizedSshKeys` (which defaults to
    the homelab key). Has no default on purpose: a manual `coder templates
    push` that forgets it fails loudly instead of silently deploying a VM
    nobody can SSH into (the Coder agent still phones home, so `coder ssh`
    keeps working either way).
  EOT
  type        = string
}

# ---------------------------------------------------------------------------
# Derived locals
# ---------------------------------------------------------------------------

locals {
  # Safe hostname: lowercase, replace non-alphanum with hyphen, max 20 chars
  vm_name   = "cdr-${lower(replace(data.coder_workspace_owner.me.name, "/[^a-zA-Z0-9]/", "-"))}-${lower(replace(data.coder_workspace.me.name, "/[^a-zA-Z0-9]/", "-"))}"
  vm_name_s = substr(local.vm_name, 0, 20)

  # Directories on the NixOS host:
  #   vm_dir        — microvm state dir (/var/lib/microvms/<name>); holds the
  #                   runner symlink, virtiofs sockets, etc. microvm.nix runs
  #                   the VM from here.
  #   flake_dir     — clean dir holding flake.nix + coder-overlay.nix; nix
  #                   build evaluates the flake from this path. Must NOT
  #                   contain socket files or other non-flake artefacts (nix
  #                   treats a path: input as the whole directory), so it's
  #                   separate from vm_dir.
  vm_dir        = "/var/lib/microvms/${local.vm_name_s}"
  flake_dir     = "/var/lib/coder-workspaces/${local.vm_name_s}/flake"
  workspace_dir = "/var/lib/coder-workspaces/${local.vm_name_s}"
  # Host directory shared (read/write) into every workspace VM at /mnt/shared
  # (see the `host-shared` virtiofs share in flake.nix.tftpl). virtiofs passes
  # the host's ownership straight through with no uid remapping, so the
  # remote-exec below chowns this to 1000:1000 — same as workspace_dir — or the
  # share would stay root-owned and the uid-1000 VM user couldn't write.
  shared_dir = "/root/vms/shared"

  # Coder access URL for the agent to phone home
  coder_url = data.coder_workspace.me.access_url

  # Comma-separated extra packages formatted as a Nix list
  extra_pkgs_list = data.coder_parameter.extra_packages.value == "" ? "" : join(" ", [
    for p in split(" ", trimspace(data.coder_parameter.extra_packages.value)) : p
    if p != ""
  ])
}

# ---------------------------------------------------------------------------
# Random stable resources (keyed to workspace ID so they survive re-plans)
# ---------------------------------------------------------------------------

resource "random_integer" "ip_octet" {
  min     = 10
  max     = 250
  keepers = { workspace_id = data.coder_workspace.me.id }
}

resource "random_id" "mac_suffix" {
  byte_length = 5
  keepers     = { workspace_id = data.coder_workspace.me.id }
}

locals {
  ip_address = "${var.bridge_subnet}.${random_integer.ip_octet.result}"
  gateway    = "${var.bridge_subnet}.1"
  # Locally-administered unicast MAC: 02:xx:xx:xx:xx:xx
  mac_address = format("02:%s", join(":", [
    substr(random_id.mac_suffix.hex, 0, 2),
    substr(random_id.mac_suffix.hex, 2, 2),
    substr(random_id.mac_suffix.hex, 4, 2),
    substr(random_id.mac_suffix.hex, 6, 2),
    substr(random_id.mac_suffix.hex, 8, 2),
  ]))
  # TAP interface name on the host (max 15 chars)
  tap_id = "cdr${random_integer.ip_octet.result}"
}

# ---------------------------------------------------------------------------
# Coder agent
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"
  dir  = "/home/${data.coder_workspace_owner.me.name}"

  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> Coder agent running inside microvm workspace"
    # Install home-manager managed packages if desired, start dev servers, etc.
    echo "==> Workspace ready."
  EOT

  metadata {
    display_name = "CPU usage"
    key          = "0_cpu"
    script       = "top -bn1 | awk '/^%Cpu/{print $2\"%\";}'"
    interval     = 10
    timeout      = 5
  }

  metadata {
    display_name = "RAM"
    key          = "1_ram"
    script       = "free -h | awk 'NR==2{printf \"%s / %s\", $3, $2}'"
    interval     = 10
    timeout      = 5
  }

  # Nix build store — bytes AND inodes. The inode figure is the one that
  # matters: the store overlay holds almost nothing but small files, so it runs
  # out of inodes long before it runs out of space, and nothing else in the
  # dashboard would show that. `/nix/.rw-store` is the volume itself; querying
  # it rather than `/nix/store` avoids relying on overlayfs statfs semantics.
  metadata {
    display_name = "Nix store"
    key          = "2_store"
    script       = "df -h /nix/.rw-store | awk 'NR==2{printf \"%s / %s\", $3, $2}'; df -i /nix/.rw-store | awk 'NR==2{printf \" (%s inodes)\", $5}'"
    interval     = 60
    timeout      = 5
  }

  # The workspace home is a virtiofs share of a host directory, so this reports
  # the HOST filesystem backing /var/lib/coder-workspaces — shared with every
  # other workspace on that host, and not a per-workspace quota. Named
  # accordingly so the number isn't read as headroom this workspace owns.
  metadata {
    display_name = "Home (host disk)"
    key          = "3_home"
    script       = "df -h /home/${data.coder_workspace_owner.me.name} | awk 'NR==2{print $3\" / \"$2}'"
    interval     = 60
    timeout      = 5
  }

  metadata {
    display_name = "NixOS"
    key          = "4_nixos"
    script       = "nixos-version 2>/dev/null || echo unknown"
    interval     = 3600
    timeout      = 5
  }
}

# Optionally expose an SSH app so users can connect via the Coder dashboard
resource "coder_app" "ssh" {
  agent_id     = coder_agent.main.id
  slug         = "ssh"
  display_name = "SSH"
  icon         = "/icon/terminal.svg"
  url          = "ssh://${local.ip_address}"
  external     = true
}

# code-server (VS Code in the browser). Unlike the dashboard's built-in
# "Open in VS Code" button (which launches the local VS Code Desktop on the
# user's workstation via a vscode:// protocol handler and so needs VS Code
# + the Coder Remote extension installed locally), this runs VS Code as a web
# app *inside the workspace VM* and the Coder dashboard opens it as a plain
# HTTPS app proxied through the agent tunnel — no local protocol handler, no
# client install, works in any browser.
#
# The flake.tftpl runs `code-server` as a systemd unit (code-server.service)
# listening on 127.0.0.1:3000 with --auth none (the dashboard's owner-scoped
# app proxy already authenticates the user). Coder proxies dashboard requests
# to http://127.0.0.1:3000/ through the agent's connection, so no VM port is
# exposed to the network.
#
# `subdomain = false` (the provider default) keeps it path-based — serves the
# app under /@<owner>/<workspace>/apps/code-server/ — so it needs NO wildcard
# DNS on `coder.<domain>` (the homelab hasn't set CODER_WILDCARD_ACCESS_URL).
# `subdomain = true` would give code-server its own hostname (avoids the
# subpath proxy quirks some web apps have) but requires wildcard DNS + the
# server's wildcard-access URL to be configured first (see caveats).
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "VS Code (web)"
  icon         = "/icon/code.svg"
  url          = "http://127.0.0.1:3000/?folder=/home/${data.coder_workspace_owner.me.name}"
  # Subdomain-based: served from its own *.coder.<internalDomain> subdomain (see
  # CODER_WILDCARD_ACCESS_URL). Requires the wildcard DNS + cert configured in
  # modules/coder/server.nix + homelab.nix; path-based serving is disabled
  # server-side (CODER_DISABLE_PATH_APPS), so `subdomain = false` would fail.
  subdomain = true
  share     = "owner"
  open_in   = "tab"

  healthcheck {
    url       = "http://127.0.0.1:3000/healthz"
    interval  = 5
    threshold = 6
  }
}

# PI WEB — web UI + persistent session manager for the Pi Coding Agent. The
# workspace's pi-web.service / pi-web-sessiond.service run it on loopback:8504
# (see flake.nix.tftpl); Coder proxies dashboard traffic to it through the
# agent tunnel. Subdomain-based like code-server — path serving is disabled
# server-side (CODER_DISABLE_PATH_APPS), and the wildcard DNS/cert are already
# configured for the other workspace apps.
resource "coder_app" "pi-web" {
  agent_id     = coder_agent.main.id
  slug         = "pi-web"
  display_name = "Pi Web"
  icon         = "/icon/terminal.svg"
  url          = "http://127.0.0.1:8504"
  subdomain    = true
  share        = "owner"
  open_in      = "tab"

  healthcheck {
    url       = "http://127.0.0.1:8504/"
    interval  = 5
    threshold = 6
  }
}

# File Browser (web file manager for /home/<owner>). Uses the official Coder
# registry module (registry.coder.com/modules/filebrowser) so the path-mode base
# URL is computed for us — needed here because the homelab has NO wildcard DNS
# (CODER_WILDCARD_ACCESS_URL is unset, see modules/coder/server.nix TODO), so we
# must use `subdomain = false` (path-based app proxy). In path mode Coder serves
# the app at /@<owner>/<workspace>.<agent>/apps/<slug>/, and filebrowser must be
# told that prefix via --baseURL — exactly the fiddly part the module handles
# (its `lifecycle.precondition` even enforces that `agent_name` is set in this
# mode). `share = "owner"` (the module default) keeps it behind the dashboard's
# owner auth, so the module's in-VM `--auth.method=noauth` is safe (same model
# as code-server's `--auth none`).
#
# Unlike code-server (baked into the VM image via a NixOS systemd unit), this
# module installs filebrowser at workspace start via a `coder_script` with
# `run_on_start = true` (idempotent — skipped once `filebrowser` is on PATH), so
# `terraform init` at `coder templates push` time fetches it from
# registry.coder.com (elserver needs internet for the push — it already has).
# Its config DB (filebrowser.db) lands in the agent's working dir
# (/home/<owner>), the virtiofs share mounted from the host's
# /var/lib/coder-workspaces/<vm> — so it persists across VM reboots.
module "filebrowser" {
  source   = "registry.coder.com/modules/filebrowser/coder"
  version  = "1.1.5"
  agent_id = coder_agent.main.id
  # `agent_name` is required only in path mode (the module's lifecycle
  # precondition enforces it when subdomain=false); kept here harmlessly so the
  # module stays valid if subdomain is ever flipped back. With subdomain=true
  # (below) the module computes an empty --baseURL and serves on its own
  # *.coder.<internalDomain> subdomain. Path serving is disabled server-side
  # (CODER_DISABLE_PATH_APPS), so subdomain must stay true.
  agent_name = "main"
  subdomain  = true
  folder     = "/home/${data.coder_workspace_owner.me.name}"
}

# ---------------------------------------------------------------------------
# Render the NixOS flake for this workspace
# ---------------------------------------------------------------------------

locals {
  # NOTE: every one of these locals is chomp()ed, and that is load-bearing —
  # see the `cat > ... << 'TERRAFORMEOF'` writes in the step-1 provisioner.
  # Those interpolate the content between two literal "\n"s, and file() /
  # templatefile() already return content ending in a newline, so writing the
  # raw value lands an EXTRA trailing newline on the host.
  #
  # For flake.nix and coder-overlay.nix that is merely untidy. For
  # pi-web/package-lock.json it broke the build: the lockfile is a file input
  # to the `fetchNpmDeps` fixed-output derivation, so one extra byte changed
  # the npm-deps output hash and every workspace build died with
  #   specified: sha256-Z0nIXS1ActFuagZ8XsLqVQyeEOQxr2dKJLixrDwWSI4=
  #   got:       sha256-ESKyxw+sjdvVCNBukf+e3H5bYRjsnJPXCHRHAM2ks9M=
  # (verified: appending one newline to the lockfile reproduces exactly that
  # second hash). chomp() strips the trailing newline so the heredoc's own
  # newline restores it, making the host's bytes identical to the repo's.
  # The step-2 provisioner now verifies that with `sha256sum -c`.

  # Pinned-Coder overlay, written next to the flake below. This is the same
  # file the Coder server applies to its own `pkgs` (it lives at
  # modules/coder/template/coder-overlay.nix), so server and agent share one
  # Coder version. See that file for bump instructions.
  coder_overlay_nix = chomp(file("${path.module}/coder-overlay.nix"))

  # `pi-web` packaging expression (adapted from github:wenjinnn/.dotfiles) plus
  # the lockfile it builds against. What it actually builds is the published npm
  # tarball, @jmfederico/pi-web, fetched from registry.npmjs.org.
  #
  # Both files live flat at the template root (a read-only Nix-store
  # subdirectory breaks the Coder template archive extractor); the step-1
  # provisioner below writes them into `${flake_dir}/pi-web/`, where the
  # generated flake builds them with `pkgs.callPackage ./pi-web/package.nix {}`.
  pi_web_package_nix  = chomp(file("${path.module}/pi-web-package.nix"))
  pi_web_package_lock = chomp(file("${path.module}/pi-web-package-lock.json"))

  # Digests of the bytes that SHOULD land on the host: the chomped content plus
  # the newline the heredoc puts back. Checked in step 2 below.
  pi_web_package_nix_sha  = sha256("${local.pi_web_package_nix}\n")
  pi_web_package_lock_sha = sha256("${local.pi_web_package_lock}\n")

  flake_nix = chomp(templatefile("${path.module}/flake.nix.tftpl", {
    vm_name               = local.vm_name_s
    hypervisor            = data.coder_parameter.hypervisor.value
    vcpus                 = data.coder_parameter.vcpus.value
    memory_mb             = data.coder_parameter.memory_mb.value
    disk_gb               = data.coder_parameter.disk_gb.value
    store_gb              = data.coder_parameter.store_gb.value
    ip_address            = local.ip_address
    gateway               = local.gateway
    mac_address           = local.mac_address
    tap_id                = local.tap_id
    username              = data.coder_workspace_owner.me.name
    workspace_dir         = local.workspace_dir
    shared_dir            = local.shared_dir
    agent_token           = coder_agent.main.token
    coder_url             = local.coder_url
    extra_pkgs            = local.extra_pkgs_list
    nix_cache_url         = var.nix_cache_url
    nix_cache_key         = var.nix_cache_key
    coder_server_ip       = var.coder_server_ip
    coder_server_hostname = var.coder_server_hostname
    authorized_ssh_keys   = var.authorized_ssh_keys
  }))
}

# ---------------------------------------------------------------------------
# VM lifecycle via null_resource + SSH remote-exec
# ---------------------------------------------------------------------------

# SSH connection (computed from the chosen microvm host). The host's
# *identity* (offsite-backup / elserver) drives power-on + keepalive decisions
# below; the *address* to reach it drives connectivity. offsite-backup's address
# is the admin var (so CODER_VM_HOST can point at a Tailscale IP); elserver is
# local to the provisioner (which runs on elserver as the Coder server), so
# 127.0.0.1 — no DNS needed and it never sleeps.
locals {
  host_ssh_address_for = {
    offsite-backup = var.host_ssh_address
    elserver       = "127.0.0.1"
  }
  chosen_host        = data.coder_parameter.microvm_host.value
  chosen_ssh_address = local.host_ssh_address_for[local.chosen_host]
  ssh_host           = split(":", local.chosen_ssh_address)[0]
  ssh_port           = length(split(":", local.chosen_ssh_address)) > 1 ? split(":", local.chosen_ssh_address)[1] : "22"
}

resource "null_resource" "microvm" {
  # Re-provision when workspace parameters or agent token change. Include the
  # chosen host so switching it (only possible by recreating the workspace —
  # it's mutable=false) re-provisions on the new host; the destroy provisioner
  # still SSHes to the OLD host via self.triggers.ssh_host.
  triggers = {
    vm_name      = local.vm_name_s
    microvm_host = local.chosen_host
    hypervisor   = data.coder_parameter.hypervisor.value
    memory_mb    = data.coder_parameter.memory_mb.value
    vcpus        = data.coder_parameter.vcpus.value
    extra_pkgs   = local.extra_pkgs_list
    # Store hashes, not raw secrets. `coder_agent.main.token` is sensitive, and
    # a sensitive value anywhere in this map marks the whole map — and therefore
    # the shared connection below — as sensitive, which makes Terraform
    # suppress every remote-exec's output. nonsensitive() strips the mark from
    # the sha256: the hash still changes when the token/flake changes (so
    # re-provisioning still works) but no sensitive value is left in the config.
    agent_token_hash = nonsensitive(sha256(coder_agent.main.token))
    flake_hash       = nonsensitive(sha256(local.flake_nix))
    # The provisioner below writes the vendored pi-web sources to the host, but
    # Terraform only re-runs provisioners when a trigger changes. Hash them too
    # so editing package.nix / its lockfile (which changes the npm-deps
    # fixed-output hash) actually rewrites the files on the host instead of
    # leaving a stale copy that fails with "hash mismatch in fixed-output
    # derivation". These are not secrets, so no nonsensitive() is needed.
    pi_web_hash     = sha256("${local.pi_web_package_nix}\n${local.pi_web_package_lock}")
    workspace_start = data.coder_workspace.me.start_count
    # SSH connection details mirrored here so the destroy-time provisioner can
    # build its own connection from self.triggers.* (Terraform forbids
    # referencing local.*/var.* in destroy provisioners and their connections).
    ssh_host             = local.ssh_host
    ssh_port             = local.ssh_port
    ssh_user             = var.host_ssh_user
    ssh_private_key_path = var.host_ssh_private_key_path
  }

  # -----------------------------------------------------------------
  # Power on the microvm host before SSHing in — but ONLY for offsite-backup
  # (it's normally powered off; elserver, the Coder server, is always on).
  #
  # This runs locally on the Coder server (elserver) as the `coder` user.
  # `systemctl start turn-on.service` IPMIs offsite-backup on and blocks until
  # its SSH is up (turn-on.service is in modules/offsite-backup.nix; the `coder`
  # user is authorised to start it via a polkit rule in modules/coder/power.nix).
  # The keepalive timestamp tells the autostop timer on elserver to hold off
  # shutting offsite-backup down while this build — which has no VM active yet
  # there — is in progress. For elserver-hosted workspaces both the power-on and
  # the keepalive are no-ops (elserver is never an autostop/turn-on target).
  #
  # Absolute binary paths are used because the Coder server's systemd unit
  # ships a minimal PATH and hardening (NoNewPrivileges etc.); polkit (not
  # setuid sudo) authorises the systemctl call, so hardening stays intact.
  # -----------------------------------------------------------------
  provisioner "local-exec" {
    when        = create
    interpreter = ["/run/current-system/sw/bin/sh", "-c"]
    command     = <<-EOT
      set -e
      /run/current-system/sw/bin/mkdir -p /var/lib/coder/vm-power
      if [ "${data.coder_parameter.microvm_host.value}" = "offsite-backup" ]; then
        /run/current-system/sw/bin/systemctl start turn-on.service
        /run/current-system/sw/bin/date -d '+${var.build_keepalive_minutes} minutes' +%s > /var/lib/coder/vm-power/keepalive-until
      fi
    EOT
  }

  # Resource-level connection shared by all provisioners. Uses self.triggers.*
  # so it's valid at both create and destroy time (Terraform forbids local.*/var.*
  # in destroy provisioners and their connections; triggers are set at create
  # and preserved to destroy).
  connection {
    type        = "ssh"
    host        = self.triggers.ssh_host
    port        = self.triggers.ssh_port
    user        = self.triggers.ssh_user
    private_key = file(self.triggers.ssh_private_key_path)
    timeout     = "3m"
  }

  # ------------------------------------------------------------------
  # Create / update the VM — step 1: write the generated Nix files.
  #
  # This provisioner's config necessarily embeds `local.flake_nix`, which
  # contains the sensitive `coder_agent.main.token`, so Terraform suppresses
  # its output. That's acceptable: it only writes files. The `nix build` /
  # `systemctl start` work is in step 2, whose config has no sensitive values,
  # so Terraform shows its output (and any failure detail).
  # ------------------------------------------------------------------
  provisioner "remote-exec" {
    inline = [
      "set -euxo pipefail",

      # 0. Ensure directories exist. vm_dir must be owned by microvm:kvm —
      #    microvm.nix's microvm-set-booted@.service runs as the `microvm` user
      #    and creates a `booted` symlink inside it.
      # Create the chosen host mount sources if missing (virtiofsd needs the
      # dir to exist; for our *flake-based* VMs the microvm.nix host module's
      # tmpfiles auto-creator does NOT run — it only iterates declarative
      # config.microvm.vms, which is empty here). Quoted against spaces.
      "mkdir -p ${local.flake_dir} ${local.workspace_dir} ${local.vm_dir} ${local.shared_dir}",

      # 1. Write the flake, the pinned-Coder overlay, and the vendored pi-web
      #    package to the clean flake_dir (not vm_dir, which will later hold
      #    runner symlinks and virtiofs sockets that break `nix build`'s path:
      #    input ingestion). The flake imports the overlay
      #    (`./coder-overlay.nix`) — the same file the Coder server applies, so
      #    agent and server versions stay equal — and builds pi-web from
      #    `./pi-web/package.nix`.
      "mkdir -p ${local.flake_dir}/pi-web",
      "cat > ${local.flake_dir}/pi-web/package.nix << 'TERRAFORMEOF'\n${local.pi_web_package_nix}\nTERRAFORMEOF",
      "cat > ${local.flake_dir}/pi-web/package-lock.json << 'TERRAFORMEOF'\n${local.pi_web_package_lock}\nTERRAFORMEOF",
      "cat > ${local.flake_dir}/coder-overlay.nix << 'TERRAFORMEOF'\n${local.coder_overlay_nix}\nTERRAFORMEOF",
      "cat > ${local.flake_dir}/flake.nix << 'TERRAFORMEOF'\n${local.flake_nix}\nTERRAFORMEOF",
    ]
  }

  # ------------------------------------------------------------------
  # Create / update the VM — step 2: ownership, build, start.
  #
  # Kept in its own provisioner, with no sensitive values in its config, so
  # Terraform does not suppress the build log (see step 1 above).
  # ------------------------------------------------------------------
  provisioner "remote-exec" {
    inline = [
      # Fail on any error — without this, a failed `nix build` or
      # `systemctl start` is silently masked by the final `echo`, and
      # terraform reports success even though the VM was never built.
      # `set -x` prints each command so the terraform log shows exactly which
      # step fails (terraform only surfaces "exit status 1" otherwise).
      "set -euxo pipefail",

      # nix otherwise emits ANSI colour escapes, which show up as unreadable
      # `[31;1m...[0m` noise in the Coder/Terraform log.
      "export NO_COLOR=1",

      # virtiofs passes host ownership straight through (no uid remapping), so
      # the workspace home AND the /mnt/shared source must be owned by 1000:1000
      # on the host — otherwise the uid-1000 VM user can read but not write.
      "chown -R 1000:1000 ${local.workspace_dir} 2>/dev/null || true",
      "chown -R 1000:1000 ${local.shared_dir} 2>/dev/null || true",
      "chown microvm:kvm ${local.vm_dir}",
      "chmod 0775 ${local.vm_dir}",

      # 2. Build the VM runner (this may take a few minutes on first run).
      #    --out-link into vm_dir so microvm@<name>.service finds current/.
      #
      #    If this fails with "hash mismatch in fixed-output derivation
      #    ...-pi-web-npm-deps.drv", do NOT just paste the reported hash into
      #    pi-web-package.nix — that pins whatever the registry happened to
      #    return this time and defeats the hash. Check first whether the
      #    lockfile changed (in which case re-pinning is correct) or whether
      #    the registry rate-limited the fetch (in which case retry). See the
      #    npmDeps comment in pi-web-package.nix.
      "echo '==> Building microvm ${local.vm_name_s}...'",
      # Verify — don't just print — that the bytes on the host are the bytes in
      # the template. package-lock.json is a file input to a fixed-output
      # derivation, so a single byte of drift turns into an npm-deps hash
      # mismatch several minutes into `nix build`, with nothing pointing back
      # at the write that caused it. `sha256sum -c` fails here instead, naming
      # the file. (This is how the stray-trailing-newline bug was found; see
      # the chomp() note on the locals above.)
      "echo '==> verifying pi-web sources on this host:'",
      "echo '${local.pi_web_package_nix_sha}  ${local.flake_dir}/pi-web/package.nix' | sha256sum -c -",
      "echo '${local.pi_web_package_lock_sha}  ${local.flake_dir}/pi-web/package-lock.json' | sha256sum -c -",
      "nix build '${local.flake_dir}#nixosConfigurations.${local.vm_name_s}.config.microvm.runner.${data.coder_parameter.hypervisor.value}' --out-link ${local.vm_dir}/current",

      # 3. Stop any existing instance then (re)start
      "systemctl stop 'microvm@${local.vm_name_s}' 2>/dev/null || true",
      "sleep 2",
      "systemctl start 'microvm@${local.vm_name_s}'",
      "echo '==> VM started. Agent will connect shortly.'",
    ]
  }

  # ------------------------------------------------------------------
  # Stop the VM when workspace is stopped (start_count == 0 handled by
  # workspace lifecycle; Coder will call destroy on delete)
  # ------------------------------------------------------------------
  provisioner "remote-exec" {
    when = destroy
    inline = [
      "systemctl stop 'microvm@${self.triggers.vm_name}' 2>/dev/null || true",
      "sleep 2",
      # Remove the VM runner symlink but keep workspace data
      "rm -f /var/lib/microvms/${self.triggers.vm_name}/current",
      "echo '==> VM stopped and deregistered.'",
    ]
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "vm_name" {
  value = local.vm_name_s
}

output "vm_ip" {
  value = local.ip_address
}

output "workspace_dir_on_host" {
  value = local.workspace_dir
}
