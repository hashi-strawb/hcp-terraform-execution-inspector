# HCP Terraform Execution Inspector

> [!WARNING]
> This project is intended for informational purposes only. It is not an
> authoritative source for HCP Terraform remote execution environment or HCP
> Terraform agent specifications, resource allocations, sizing requirements,
> supported software, or performance guarantees. It is not an official HashiCorp
> specification. Observations from a run may be virtualized, incomplete, or change
> between runs; they must not be treated as a supported service contract.

Collect runner-visible CPU, memory, storage, operating-system, runtime, and
process/container-limit observations using Terraform `null_resource` resources
with `local-exec` provisioners. Results are exposed through the `machine_stats`
Terraform output.

The goal is to inform an initial sizing and compatibility investigation for a
customer-managed HCP Terraform agent, not to derive an equivalent agent
specification from a hosted run. Validate candidate infrastructure with the
customer's representative workloads and intended concurrency before choosing a
production configuration.

## Terminology

HashiCorp's [workspace execution-mode documentation](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/settings#execution-mode)
distinguishes:

- **Remote execution mode:** HCP Terraform performs runs on its own disposable
  virtual machines.
- **Agent execution mode:** HCP Terraform communicates with lightweight
  **HCP Terraform agents** to run Terraform in isolated, private, or on-premises
  infrastructure.
- **Local execution mode:** Terraform runs on the operator's local workstation;
  HCP Terraform can still store the workspace's state.

This README uses **HCP Terraform remote execution environment** for the
environment observed in remote execution mode, and **customer-managed HCP
Terraform agent** for an agent deployed on customer-controlled infrastructure.
It does not use "hosted agent" as the name of an execution mode. An internal
process name or filesystem path containing `tfc-agent` does not establish a
workspace's execution mode; check the workspace settings.

Refer to the official [HCP Terraform Agents documentation](https://developer.hashicorp.com/terraform/cloud-docs/agents)
for agent deployment and requirements, and the workspace documentation above
for execution-mode behavior. Those documents, not this repository's observations,
are the source of product guidance.

## Usage

1. Use a dedicated HCP Terraform workspace and select the execution mode you want
   to inspect. For a customer-managed agent, select agent execution mode and the
   appropriate agent pool.
2. Edit the `cloud` block in [main.tf](main.tf) to select your HCP Terraform
   hostname, organization, and workspace. The checked-in values refer to the
   author's HCP Terraform Europe test workspace; they are not generic defaults.
3. Authenticate with that hostname, then initialize, plan, and apply:

   ```sh
   terraform login app.eu.terraform.io
   terraform init
   terraform plan
   terraform apply
   terraform output machine_stats
   ```

   Substitute your configured hostname in the login command. The account must
   have permission to run plans and applies in the chosen workspace.

The CLI submits runs to HCP Terraform when the workspace is in remote or agent
execution mode. `local-exec` means local to the Terraform process executing the
run, not necessarily local to your workstation. In local execution mode, the
provisioners inspect your workstation instead.

A plan does not execute provisioners; fresh statistics are known only after
apply. The `timestamp()` trigger replaces all five null resources on every
apply, so a separate destroy is not needed to collect another sample. This
configuration does not provision customer infrastructure or install agent
software, but it does create resources in Terraform state and report files in
the execution environment.

## Collected Information

| Output section | Observations |
| --- | --- |
| `cpu` | Visible processor count, architecture, compact CPU topology/model, and collector affinity when exposed |
| `memory` | Visible total/available memory and swap |
| `disk` | Working-directory and temporary-directory capacity and inodes, with warnings for synthetic capacity or unavailable inode counts |
| `system` | OS/kernel, user identity, Terraform version when accessible, libc version, and selected provisioner-tool availability |
| `limits` | Shell limits and resolved workload cgroup CPU, cpuset, memory, and PID metrics, including visible ancestors |

Tool availability is an observation, not an installation requirement or a
promise that those tools will be available in future runs. Missing commands and
unsupported metrics are expected in restricted execution environments.

## Interpretation And Limitations

- Visible CPUs and memory do not establish guaranteed or exclusive allocations.
  CPU count alone does not establish equivalent processor performance.
- Effective capacity can be constrained by affinity, cgroup limits, ancestor
  limits, and scheduling. Hidden ancestors and scheduler policies cannot be
  inferred. An `unlimited` visible cgroup is not proof of unlimited service
  capacity.
- Cgroup membership is resolved against the process's mount information. If
  workload directories are inaccessible, limits are reported as unknown rather
  than substituting unrelated root-cgroup limits.
- Filesystem capacity may be synthetic. The temporary directory may be
  memory-backed; reported storage is not a guaranteed persistent-disk allocation.
- Collector affinity describes the provisioner subprocess, not a direct
  measurement of Terraform's affinity. Peak-memory and OOM metrics are reported
  only where readable; cgroup measurements are not isolated Terraform-process
  measurements.
- Terraform may be absent from the provisioner's `PATH`, and process ancestry
  may be inaccessible. In that case, use the Terraform version in the remote
  run header. OS/kernel values can also be virtualized.
- These lightweight snapshots do not benchmark CPU, disk, network, Terraform
  duration, or representative-workload peak memory. They cannot certify an
  equivalent self-hosted environment.
- Linux has the most complete collection support. macOS has basic CPU, memory,
  and system fallbacks; cgroup metrics are unavailable there. Windows is not
  supported by this POSIX shell collector.

## Handling Reports

Reports are stored in Terraform outputs/state and displayed in run output.
They can contain usernames, filesystem paths, and environment characteristics.
Review and redact reports before sharing them publicly. The collector does not
dump environment variables or credentials, but its output is not a general
redaction or security guarantee.

Terraform state, provider caches, local variable files, and credential files are
excluded from Git. Provider selections are recorded in the committed dependency
lock file. Do not commit generated reports or credential-bearing configuration.